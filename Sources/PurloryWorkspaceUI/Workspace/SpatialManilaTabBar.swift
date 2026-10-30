import AppKit
import SwiftUI

struct SpatialManilaTabBar: NSViewRepresentable {
    @ObservedObject var session: ProjectSession
    @ObservedObject var model: SpatialWorkspaceController
    let documentID: WritingDocumentID
    let theme: PurloryTheme

    func makeNSView(context: Context) -> SpatialManilaTabBarView { SpatialManilaTabBarView() }
    func updateNSView(_ view: SpatialManilaTabBarView, context: Context) {
        let slot = model.layout.slot(containing: .document(documentID))
        view.configure(documents: (slot?.tabs ?? [documentID]).compactMap { session.document($0) },
            active: slot?.tile.documentID ?? documentID, theme: theme, quiet: model.whisperTyping,
            typewriter: model.typewriter, focus: model.focusDimming, canCreate: session.isEditorEditable,
            activate: { model.whisperTyping = false; model.open($0) }, close: { _ = model.close(.document($0)) },
            create: { model.open(documentID); _ = session.createDocument() },
            toggleTypewriter: { model.typewriter.toggle() }, toggleFocus: { model.focusDimming.toggle() })
        if case .tab(let anchor, let index) = model.previewTarget, slot?.contains(anchor) == true {
            view.showInsertion(at: index)
        } else { view.showInsertion(at: nil) }
    }
}

/// Opaque paper tabs. The scrolling strip owns tab hit testing; the canvas owns drag capture.
final class SpatialManilaTabBarView: NSView {
    static let height: CGFloat = 34
    private let scroll = NSScrollView()
    private let strip = FlippedView()
    private let plus = WorkspacePouchButton(frame: .zero)
    private let typewriter = WorkspacePouchButton(frame: .zero)
    private let focus = WorkspacePouchButton(frame: .zero)
    private(set) var tabs: [SpatialManilaTabButton] = []
    private var active: WritingDocumentID?
    private var theme: PurloryTheme = .light
    private var create: (() -> Void)?
    private var toggleTypewriter: (() -> Void)?
    private var toggleFocus: (() -> Void)?
    private var revealActive = true
    private let insertion = InsertionMarker()
    private var insertionIndex: Int?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("원고 서류철"); setAccessibilityIdentifier("purlory.binder.tabs")
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        addSubview(scroll); strip.addSubview(plus)
        insertion.wantsLayer = true; insertion.isHidden = true; insertion.setAccessibilityElement(false)
        strip.addSubview(insertion)
        addSubview(typewriter); addSubview(focus)
        configureButton(plus, symbol: "plus", label: "새 원고", id: "purlory.binder.new", action: #selector(newDocument))
        configureButton(typewriter, symbol: "align.vertical.center", label: "타자기 모드", id: "purlory.binder.typewriter", action: #selector(changeTypewriter))
        configureButton(focus, symbol: "circle.lefthalf.filled", label: "문단 집중 모드", id: "purlory.binder.focus", action: #selector(changeFocus))
    }
    required init?(coder: NSCoder) { nil }

    private func configureButton(_ button: WorkspacePouchButton, symbol: String, label: String, id: String, action: Selector) {
        button.target = self; button.action = action; button.isBordered = false
        button.title = ""; button.imagePosition = .imageOnly
        button.refusesFirstResponder = true; button.draggable = false
        button.image = WorkspaceIcons.image(symbol, size: 11)
        button.toolTip = label; button.setAccessibilityLabel(label); button.setAccessibilityIdentifier(id)
    }

    func configure(documents: [WritingDocument], active: WritingDocumentID, theme: PurloryTheme, quiet: Bool,
                   typewriter: Bool, focus: Bool, canCreate: Bool,
                   activate: @escaping (WritingDocumentID) -> Void, close: @escaping (WritingDocumentID) -> Void,
                   create: @escaping () -> Void, toggleTypewriter: @escaping () -> Void, toggleFocus: @escaping () -> Void) {
        revealActive = revealActive || self.active != active || tabs.map(\.documentID) != documents.map(\.id)
        self.active = active; self.theme = theme; self.create = create
        self.toggleTypewriter = toggleTypewriter; self.toggleFocus = toggleFocus
        let previous = Dictionary(uniqueKeysWithValues: tabs.map { ($0.documentID, $0) })
        for tab in tabs where !documents.contains(where: { $0.id == tab.documentID }) { tab.removeFromSuperview() }
        tabs = documents.map { document in
            let tab = previous[document.id] ?? SpatialManilaTabButton(documentID: document.id)
            tab.title = document.title.isEmpty ? "제목 없음" : document.title
            tab.active = document.id == active; tab.theme = theme
            tab.activate = { activate(document.id) }; tab.close = { close(document.id) }
            tab.alphaValue = quiet && !tab.active ? 0.35 : 1
            tab.setAccessibilityLabel(tab.title)
            tab.setAccessibilityValue(NSNumber(value: tab.active))
            tab.toolTip = tab.title
            if tab.superview == nil { strip.addSubview(tab) }
            tab.refresh(); return tab
        }
        for (index, tab) in tabs.enumerated() {
            // A selected tab supplies its own silhouette; separators belong only
            // between neighboring inactive labels on the shared strip.
            tab.showsTrailingSeparator = !tab.active && index + 1 < tabs.count && !tabs[index + 1].active
            tab.needsDisplay = true
        }
        plus.isEnabled = canCreate; plus.alphaValue = quiet ? 0.35 : 1
        self.typewriter.selected = typewriter; self.focus.selected = focus
        for button in [plus, self.typewriter, self.focus] {
            button.theme = theme; button.refresh()
            button.setAccessibilityValue(NSNumber(value: button.selected))
        }
        insertion.layer?.backgroundColor = theme.novel.cgColor
        strip.addSubview(insertion, positioned: .above, relativeTo: nil)
        needsLayout = true; needsDisplay = true
    }

    func showInsertion(at index: Int?) {
        insertionIndex = index; insertion.isHidden = index == nil; needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - 64), height: Self.height)
        typewriter.frame = CGRect(x: max(0, bounds.width - 60), y: 5, width: 26, height: 26)
        focus.frame = CGRect(x: max(0, bounds.width - 32), y: 5, width: 26, height: 26)
        var x: CGFloat = 4
        for tab in tabs {
            let measured = (tab.title as NSString).size(withAttributes: [.font: PurloryFonts.ui(11.5, weight: .semibold)]).width
            let width = min(200, max(100, ceil(measured) + 52))
            tab.frame = CGRect(x: x, y: 0, width: width, height: Self.height)
            x += width - 1
        }
        plus.frame = CGRect(x: x + 3, y: 5, width: 26, height: 26)
        strip.frame = CGRect(x: 0, y: 0, width: max(scroll.bounds.width, x + 34), height: Self.height)
        if let index = insertionIndex {
            let edge = tabs.indices.contains(index) ? tabs[index].frame.minX : (tabs.last?.frame.maxX ?? 4)
            insertion.frame = CGRect(x: edge, y: 8, width: 2, height: 23)
        }
        if revealActive, let tab = tabs.first(where: \.active) {
            let trailing: CGFloat = tab === tabs.last ? 34 : 0
            tab.scrollToVisible(CGRect(x: 0, y: 0, width: tab.bounds.width + trailing, height: tab.bounds.height))
            revealActive = false
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.cardSurface.setFill(); bounds.fill()
        theme.sepStrong.setStroke()
        let line = NSBezierPath(); line.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
        line.move(to: CGPoint(x: 0, y: bounds.maxY - line.lineWidth / 2))
        line.line(to: CGPoint(x: bounds.maxX, y: bounds.maxY - line.lineWidth / 2)); line.stroke()
    }

    func dropTarget(at point: CGPoint) -> SpatialDropTarget? {
        guard bounds.contains(point), let active else { return nil }
        let local = strip.convert(point, from: self)
        let index = tabs.firstIndex { local.x < $0.frame.midX } ?? tabs.count
        return .tab(.document(active), index: index)
    }

    @objc private func newDocument() { create?() }
    @objc private func changeTypewriter() { toggleTypewriter?() }
    @objc private func changeFocus() { toggleFocus?() }
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    private final class InsertionMarker: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}

final class SpatialManilaTabButton: NSButton {
    let documentID: WritingDocumentID
    var active = false
    var showsTrailingSeparator = false
    var theme: PurloryTheme = .light
    var activate: (() -> Void)?
    var close: (() -> Void)?
    private let closeButton = WorkspacePouchButton(frame: .zero)
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(documentID: WritingDocumentID) {
        self.documentID = documentID
        super.init(frame: .zero)
        isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(selectTab)
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("purlory.binder.tab.\(documentID.rawValue.uuidString)")
        closeButton.isBordered = false; closeButton.draggable = false; closeButton.refusesFirstResponder = true
        closeButton.title = ""; closeButton.imagePosition = .imageOnly
        closeButton.target = self; closeButton.action = #selector(closeTab)
        closeButton.image = WorkspaceIcons.image("xmark", size: 9)
        closeButton.toolTip = "원고 탭 닫기"; closeButton.setAccessibilityLabel("원고 탭 닫기")
        closeButton.setAccessibilityIdentifier("purlory.binder.close.\(documentID.rawValue.uuidString)")
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        closeButton.theme = theme; closeButton.refresh()
        closeButton.alphaValue = hovered || window?.firstResponder === self ? 1 : 0
        needsDisplay = true; needsLayout = true
    }
    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: bounds.width - 28, y: 8, width: 20, height: 20)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); refresh(); return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); refresh(); return accepted }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    @objc private func selectTab() { activate?() }
    @objc private func closeTab() { close?() }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { close?() } else { super.otherMouseUp(with: event) } }
    override func mouseDown(with event: NSEvent) {
        let canvas = enclosingSpatialCanvas
        activate?()
        canvas?.beginPanelDrag(.document(documentID), event: event)
    }
    override func mouseDragged(with event: NSEvent) { enclosingSpatialCanvas?.continuePanelDrag(event) }
    override func mouseUp(with event: NSEvent) { enclosingSpatialCanvas?.finishPanelDrag(event) }
    override func cancelOperation(_ sender: Any?) { enclosingSpatialCanvas?.cancelInteraction() }

    override func draw(_ dirtyRect: NSRect) {
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let top: CGFloat = 4
        let bottom = bounds.height
        let left: CGFloat = 6, right = bounds.width - 6, r: CGFloat = 6
        if active {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 0, y: bottom))
            path.curve(to: CGPoint(x: left, y: bottom - r), controlPoint1: CGPoint(x: left, y: bottom), controlPoint2: CGPoint(x: left, y: bottom))
            path.line(to: CGPoint(x: left, y: top + r))
            path.curve(to: CGPoint(x: left + r, y: top), controlPoint1: CGPoint(x: left, y: top), controlPoint2: CGPoint(x: left, y: top))
            path.line(to: CGPoint(x: right - r, y: top))
            path.curve(to: CGPoint(x: right, y: top + r), controlPoint1: CGPoint(x: right, y: top), controlPoint2: CGPoint(x: right, y: top))
            path.line(to: CGPoint(x: right, y: bottom - r))
            path.curve(to: CGPoint(x: bounds.width, y: bottom), controlPoint1: CGPoint(x: right, y: bottom), controlPoint2: CGPoint(x: right, y: bottom))
            theme.editorSurface.setFill(); path.fill()
            theme.novel.setFill(); NSBezierPath(ovalIn: CGRect(x: 15, y: top + 12, width: 6, height: 6)).fill()
        } else if showsTrailingSeparator {
            theme.sepStrong.setFill()
            CGRect(x: bounds.width - 1, y: 11, width: pixel, height: 14).fill()
        }
        let textX: CGFloat = active ? 27 : 15
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: CGRect(x: textX, y: top + 8, width: max(0, bounds.width - textX - 29), height: 17),
            withAttributes: [.font: PurloryFonts.ui(11.5, weight: active ? .semibold : .regular),
                .foregroundColor: active ? theme.ink : theme.ink2, .paragraphStyle: paragraph])
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 7), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2; ring.stroke()
        }
    }
}
