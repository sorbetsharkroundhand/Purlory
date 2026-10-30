import AppKit
import Combine
import CryptoKit
import SwiftUI

@MainActor final class WorkspaceEntityController: ObservableObject {
    struct Peek: Equatable {
        let name: String; let note: String; let aliases: String
        let badge: String; let role: String; let tags: String
        let reference: OriginalSourceReference
    }
    private struct Record {
        let name: String; let aliases: String; let note: String
        let badge: String; let role: String; let tags: String
        let reference: OriginalSourceReference?
    }
    @Published private(set) var peek: Peek?
    private weak var session: ProjectSession?
    private weak var requests: ProjectEditorRequests?
    private var hideTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var records: [Record] = []
    private var events: [Record] = []
    private var cachedNotes: [WritingDocument] = []
    private var cachedTrash: Set<WritingDocumentID> = []
    private weak var highlightedEditor: BlockTextView?
    private var highlightedRange: NSRange?
    private var cachedData: [String: Data] = [:]
    private var projectID: WritingProjectID?
    private var provenNativeRevision: UInt64?
    private var provenNativeRange: NSRange?
    private var subscriptions: Set<AnyCancellable> = []
    init(session: ProjectSession, requests: ProjectEditorRequests) {
        self.session = session; self.requests = requests
        session.$activeProject.sink { [weak self] project in
            guard let self else { return }
            self.hide()
            guard let project else { self.records = []; return }
            let notes = project.documents.filter { $0.kind == .note && !project.trashedDocumentIDs.contains($0.id) }
            guard project.id != self.projectID || project.userData != self.cachedData || notes != self.cachedNotes || project.trashedDocumentIDs != self.cachedTrash else { return }
            self.projectID = project.id; self.cachedData = project.userData
            self.cachedNotes = notes; self.cachedTrash = project.trashedDocumentIDs
            var seen: Set<UUID> = []
            self.records = project.documents.filter { !project.trashedDocumentIDs.contains($0.id) }.flatMap { document in
                (try? WriterDocumentData.decode(project.userData[WriterDocumentData.key(for: document.id)], documentID: document.id).characters) ?? []
            }.filter { !$0.name.isEmpty && $0.autoRegistered != true && seen.insert($0.id).inserted }.map {
                Record(name: $0.name, aliases: $0.aliases, note: $0.note, badge: "인물", role: $0.role ?? "",
                    tags: ($0.traits ?? []).map { "#" + $0 }.joined(separator: " "), reference: nil)
            }
            for note in notes {
                let source = note.body as NSString
                var cursor = 0, headings: [(String, NSRange)] = []
                while cursor < source.length {
                    let range = source.paragraphRange(for: NSRange(location: cursor, length: 0)); cursor = range.upperBound
                    let line = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.hasPrefix("#"), let space = line.firstIndex(of: " "), line[..<space].allSatisfy({ $0 == "#" }) {
                        headings.append((String(line[line.index(after: space)...]), range))
                    }
                }
                if headings.isEmpty, source.length > 0 { headings = [(note.title, NSRange(location: 0, length: 0))] }
                for (index, heading) in headings.enumerated() where !heading.0.isEmpty && heading.0.count <= 80 {
                    let end = index + 1 < headings.count ? headings[index + 1].1.location : source.length
                    let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: heading.1.location, length: min(1024, end - heading.1.location)))
                    guard range.length > 0, let reference = OriginalSourceReference.exact(
                        .init(documentID: note.id, quote: source.substring(with: range), utf16Hint: range.location), in: project) else { continue }
                    let text = source.substring(with: NSRange(location: heading.1.upperBound, length: max(0, end - heading.1.upperBound)))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.records.append(.init(name: heading.0, aliases: "", note: String(text.prefix(240)), badge: "고증", role: note.title, tags: "", reference: reference))
                }
            }
            self.updateTerms()
        }.store(in: &subscriptions)
        requests.spatialWorkspace?.$entityEvents.sink { [weak self] values in
            guard let self else { return }
            self.events = values.map { .init(name: $0.name, aliases: "", note: $0.note, badge: "사건", role: "서사 흐름", tags: "", reference: $0.reference) }
            self.updateTerms()
        }.store(in: &subscriptions)
        requests.spatialWorkspace?.$whisperTyping.sink { [weak self] value in if value { self?.hide() } }.store(in: &subscriptions)
        requests.spatialWorkspace?.$isDragging.sink { [weak self] value in if value { self?.hide() } }.store(in: &subscriptions)
    }
    private func updateTerms() {
        requests?.spatialWorkspace?.entityTerms = (records + events).flatMap {
            [$0.name] + $0.aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { !$0.isEmpty }
    }
    func hover(editor: BlockTextView, key: ProjectDocumentKey, nativeOffset: Int) {
        guard let session, session.isEditorEditable, session.activeProject?.id == key.projectID,
              requests?.spatialWorkspace?.whisperTyping != true, requests?.spatialWorkspace?.isDragging != true,
              !editor.hasMarkedText(), let document = session.document(key.documentID) else { scheduleHide(); return }
        let native = editor.string as NSString
        guard nativeOffset >= 0, nativeOffset < native.length else { scheduleHide(); return }
        let line = native.paragraphRange(for: .init(location: nativeOffset, length: 0))
        for card in records + events {
            if let reference = card.reference {
                guard reference.key.projectID == session.activeProject?.id,
                      let target = session.document(reference.key.documentID),
                      reference.matchesSource(target.body) else { continue }
            }
            for term in [card.name] + card.aliases.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !term.isEmpty && term.count <= 80 {
                var start = line.location
                while start < line.upperBound {
                    let range = native.range(of: term, range: .init(location: start, length: line.upperBound - start))
                    guard range.location != NSNotFound else { break }; start = range.upperBound
                    guard NSLocationInRange(nativeOffset, range) else { continue }
                    let original = document.body as NSString
                    if peek?.name == card.name && peek?.reference.key == key && provenNativeRevision == editor.writingNativeRevision && provenNativeRange == range {
                        keepAlive(); return
                    }
                    guard editor.serialize().utf16.elementsEqual(document.body.utf16) else { continue }
                    let start = editor.sourceCursorOffset(at: range.location), end = editor.sourceCursorOffset(at: range.upperBound)
                    let source = NSRange(location: start, length: end - start)
                    guard start >= 0, end > start, end <= original.length, source.length <= 2048,
                          original.rangeOfComposedCharacterSequences(for: source) == source else { continue }
                    provenNativeRevision = editor.writingNativeRevision; provenNativeRange = range
                    let reference = OriginalSourceReference(key: key, revision: SHA256.hash(data: Data(document.body.utf8)).map { String(format: "%02x", $0) }.joined(),
                        evidence: .init(documentID: key.documentID, quote: original.substring(with: source), utf16Hint: source.location), selection: .passage)
                    let next = Peek(name: card.name, note: card.note, aliases: card.aliases, badge: card.badge,
                        role: card.role, tags: card.tags, reference: card.reference ?? reference)
                    clearHighlight()
                    highlightedEditor = editor; highlightedRange = range
                    editor.layoutManager?.addTemporaryAttribute(.foregroundColor, value: editor.palette.novel, forCharacterRange: range)
                    editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: editor.palette.novelBg, forCharacterRange: range)
                    keepAlive(); requests?.spatialWorkspace?.resonatingTerm = term
                    if peek != next { peek = next; present(next, editor: editor, range: range) }
                    return
                }
            }
        }
        scheduleHide()
    }
    func keepAlive() { hideTask?.cancel(); hideTask = nil }
    func scheduleHide() {
        guard hideTask == nil, peek != nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(190)); guard !Task.isCancelled else { return }; self?.hide()
        }
    }
    func hide() {
        keepAlive(); peek = nil; clearHighlight()
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
        panel = nil; requests?.spatialWorkspace?.resonatingTerm = nil
    }
    private func clearHighlight() {
        if let editor = highlightedEditor, let range = highlightedRange, range.upperBound <= editor.string.utf16.count {
            editor.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            editor.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        highlightedEditor = nil; highlightedRange = nil
    }
    private func present(_ value: Peek, editor: BlockTextView, range: NSRange) {
        guard let parent = editor.window else { return }
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 268, height: 108), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "인물·고증·사건"
        panel.isReleasedWhenClosed = false; panel.hasShadow = true; panel.level = .floating; panel.hidesOnDeactivate = true
        panel.isOpaque = false; panel.backgroundColor = .clear
        let theme = editor.palette
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(value.badge).purloryUIFont(9.5, .semibold).foregroundStyle(theme.novelC)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(theme.novelBgC, in: RoundedRectangle(cornerRadius: 4))
                Text(value.name).font(PurloryFonts.serifUI(12, .bold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(value.role).purloryUIFont(10).foregroundStyle(theme.workspaceMutedC).lineLimit(1)
            }
            Text(value.note).purloryUIFont(11).lineSpacing(4).foregroundStyle(theme.ink2C).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(value.tags).purloryUIFont(10).foregroundStyle(theme.workspaceMutedC).lineLimit(1)
                Spacer(minLength: 4)
                Button("관련 문단 →") { [weak self] in
                    guard let self, let session = self.session, let requests = self.requests else { return }
                    let inspection = ProjectSourceInspection(session: session)
                    if let token = inspection.capture() { requests.jump(to: value.reference, inspection: inspection, token: token, in: session) }
                    self.hide()
                }.buttonStyle(.plain).purloryUIFont(10, .medium).foregroundStyle(theme.novelC)
            }.padding(.top, 4)
        }.padding(12).frame(width: 268, alignment: .leading).foregroundStyle(theme.inkC)
            .background(theme.pillC, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(theme.pillBorderC))
            .onHover { [weak self] inside in if inside { self?.keepAlive() } else { self?.scheduleHide() } })
        panel.contentView = host
        let height = max(92, host.fittingSize.height)
        panel.setContentSize(.init(width: 268, height: height))
        let anchor = editor.firstRect(forCharacterRange: range, actualRange: nil)
        let visible = parent.screen?.visibleFrame ?? parent.frame
        let target = CGPoint(x: max(visible.minX + 14, min(visible.maxX - 282, anchor.midX - 134)),
            y: min(visible.maxY - height - 14, anchor.maxY + 108 - height))
        panel.setFrameOrigin(.init(x: target.x, y: target.y - 4)); panel.alphaValue = 0
        parent.addChildWindow(panel, ordered: .above); panel.orderFront(nil); self.panel = panel
        WorkspaceHTMLStyle.animate(0.22) { panel.animator().setFrameOrigin(target); panel.animator().alphaValue = 1 }
    }
}
