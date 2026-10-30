import AppKit
import Combine

/// Read-only Markdown with packet-owned links; appending never replaces the writer's selection.
@MainActor
final class AskAnswerView: NSScrollView, NSTextViewDelegate {
    let textView: NSTextView = AskResultTextView()
    var onSource: ((UUID, String) -> Void)?
    var onCancel: (() -> Void)?
    private var packetID: UUID?
    private var sources: Set<String> = []
    private var rendered: [AskAnswerBlock] = []
    private var following = true, applying = false
    private var subscriptions: Set<AnyCancellable> = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true; borderType = .bezelBorder
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false; textView.allowsUndo = false
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8); textView.delegate = self
        textView.setAccessibilityLabel("원문 근거와 AI 답변"); textView.setAccessibilityIdentifier("purlory.ask.answer")
        documentView = textView; contentView.postsBoundsChangedNotifications = true
        if let result = textView as? AskResultTextView {
            result.cancel = { [weak self] in self?.onCancel?() }
            result.navigate = { [weak self] backward in self?.navigateLink(backward: backward) ?? false }
            result.activate = { [weak self] in self?.activateSelectedLink() ?? false }
        }
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: contentView)
            .sink { [weak self] _ in self?.noteUserScroll() }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { nil }
    func noteUserScroll() {
        guard !applying else { return }
        following = contentView.bounds.maxY >= textView.bounds.height - 24
    }
    static func sourceURL(packetID: UUID, sourceID: String) -> URL {
        URL(string: "purlory-source://\(packetID.uuidString.lowercased())/\(sourceID)")!
    }
    func activateSourceLink(_ url: URL) -> Bool {
        guard let packetID, let id = url.pathComponents.last, sources.contains(id),
              url == Self.sourceURL(packetID: packetID, sourceID: id) else { return false }
        onSource?(packetID, id); return true
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { _ = activateSourceLink(url) }
        return true // Never let AppKit open a model-supplied URL.
    }
    private func navigateLink(backward: Bool) -> Bool {
        var ranges: [NSRange] = []
        let length = textView.string.utf16.count
        textView.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: length)) { value, range, _ in
            if value is URL { ranges.append(range) }
        }
        let location = textView.selectedRange().location
        let target = backward ? ranges.last(where: { $0.location < location }) : ranges.first(where: { $0.location > location })
        guard let target else { return false }
        textView.setSelectedRange(target); textView.scrollRangeToVisible(target); return true
    }
    private func activateSelectedLink() -> Bool {
        let location = textView.selectedRange().location
        guard location < textView.string.utf16.count,
              let url = textView.textStorage?.attribute(.link, at: location, effectiveRange: nil) as? URL else { return false }
        return activateSourceLink(url)
    }
    func update(packet: AskEvidencePacket?, blocks: [AskAnswerBlock]) {
        let blocks = blocks.filter { $0.packetID == packet?.id }
        guard packetID != packet?.id || rendered != blocks else { return }
        applying = true; defer { applying = false }
        let selection = textView.selectedRange(), follows = following
        let prefix = packetID == packet?.id && blocks.starts(with: rendered)
        if !prefix { textView.textStorage?.setAttributedString(NSAttributedString(string: "")); rendered = []; following = true }
        packetID = packet?.id; sources = Set(packet?.sources.map(\.id) ?? [])
        for block in blocks.dropFirst(rendered.count) {
            let display = (packet?.sources ?? []).reduce(block.text) { text, source in
                text.replacingOccurrences(of: "[\(source.id)]", with: "[\(source.id.dropFirst())]")
            }
            let markdown = (try? AttributedString(markdown: display)) ?? AttributedString(display)
            let body = NSMutableAttributedString(attributedString: NSAttributedString(markdown))
            var runOffset = 0
            for run in markdown.runs {
                let intent = run.inlinePresentationIntent
                let font = intent?.contains(.code) == true ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                    : intent?.contains(.stronglyEmphasized) == true ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
                // AppKit fonts stay in the main-actor-owned native string. Swift's
                // AttributedString attribute values require Sendable conformance.
                let length = String(markdown[run.range].characters).utf16.count
                body.addAttribute(.font, value: font, range: NSRange(location: runOffset, length: length))
                runOffset += length
            }
            let whole = NSRange(location: 0, length: body.length)
            body.removeAttribute(.link, range: whole); body.removeAttribute(.attachment, range: whole)
            body.append(NSAttributedString(string: "\n"))
            for citation in block.citations where sources.contains(citation.sourceID) {
                body.append(NSAttributedString(string: "원문 \(citation.sourceID.dropFirst())", attributes: [
                    .link: Self.sourceURL(packetID: block.packetID, sourceID: citation.sourceID),
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.controlAccentColor]))
                body.append(NSAttributedString(string: "  \(citation.quote)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            body.append(NSAttributedString(string: "\n")); textView.textStorage?.append(body)
        }
        rendered = blocks
        textView.setFrameSize(NSSize(width: contentView.bounds.width, height: max(contentView.bounds.height, textView.frame.height)))
        textView.textContainer?.containerSize = NSSize(width: max(1, contentView.bounds.width - 16), height: .greatestFiniteMagnitude)
        if let container = textView.textContainer, let manager = textView.layoutManager {
            manager.ensureLayout(for: container)
            textView.setFrameSize(NSSize(width: contentView.bounds.width,
                height: max(contentView.bounds.height, manager.usedRect(for: container).height + 16)))
        }
        let length = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - min(selection.location, length)))))
        if follows || !prefix { textView.scrollRangeToVisible(NSRange(location: length, length: 0)) }
    }
}

@MainActor
private final class AskResultTextView: NSTextView {
    var cancel: (() -> Void)?
    var navigate: ((Bool) -> Bool)?
    var activate: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) { cancel?() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 48 {
                let backward = event.modifierFlags.contains(.shift)
                if navigate?(backward) != true {
                    if backward { window?.selectPreviousKeyView(nil) } else { window?.selectNextKeyView(nil) }
                }
                return
            }
            if event.keyCode == 36, activate?() == true { return }
            if event.keyCode == 53 { cancel?(); return }
        }
        super.keyDown(with: event)
    }
}
