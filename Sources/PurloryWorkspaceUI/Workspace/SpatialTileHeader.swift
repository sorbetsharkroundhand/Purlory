import AppKit
import SwiftUI

struct SpatialHeaderAction {
    let id: String
    let label: String
    let symbol: String
    var title = ""
    var selected = false
    var enabled = true
    let perform: () -> Void
}

struct SpatialTileHeader: NSViewRepresentable {
    let tile: WorkspaceTileID
    let title: String
    let theme: PurloryTheme
    var active = false
    var actions: [SpatialHeaderAction] = []

    func makeNSView(context: Context) -> SpatialTileHeaderView { SpatialTileHeaderView() }
    func updateNSView(_ view: SpatialTileHeaderView, context: Context) {
        view.tile = tile; view.title.stringValue = title; view.theme = theme; view.active = active
        view.title.textColor = tile.documentID == nil ? theme.ink2 : (active ? theme.ink : theme.workspaceMuted)
        view.title.font = PurloryFonts.ui(11, weight: active ? .semibold : .medium)
        view.setAccessibilityIdentifier("purlory.tile.header.\(tile.id)")
        view.setAccessibilityLabel(title + " — 드래그하여 배치")
        view.configure(actions); view.needsLayout = true; view.needsDisplay = true
    }
}

final class SpatialTileHeaderView: NSView {
    var tile: WorkspaceTileID = .navigator
    var theme: PurloryTheme = .light
    var active = false
    let title = PassthroughTitle(labelWithString: "")
    private var buttons: [WorkspacePouchButton] = []
    private let icon = PassthroughIcon()
    private var actions: [SpatialHeaderAction] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail; title.maximumNumberOfLines = 1
        title.setAccessibilityElement(false); addSubview(title)
        icon.setAccessibilityElement(false); addSubview(icon)
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ supplied: [SpatialHeaderAction]) {
        var actions = supplied
        if !actions.contains(where: { $0.symbol == "xmark" }) {
            actions.append(SpatialHeaderAction(id: "purlory.tile.close.\(tile.id)", label: "객체 닫기", symbol: "xmark") { [weak self] in
                guard let self else { return }; self.canvas?.model?.dismissObject?(self.tile)
            })
        }
        self.actions = actions
        while buttons.count > actions.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < actions.count {
            let button = WorkspacePouchButton(frame: .zero)
            button.target = self; button.action = #selector(invoke(_:))
            buttons.append(button); addSubview(button)
        }
        for (index, action) in actions.enumerated() {
            let button = buttons[index]
            button.refusesFirstResponder = false
            button.tag = index; button.title = action.title
            button.draggable = false
            button.font = PurloryFonts.ui(10.5, weight: action.selected ? .semibold : .regular)
            button.image = action.symbol.isEmpty ? nil : WorkspaceIcons.image(action.symbol, size: action.title.isEmpty ? 12 : 10)
            button.toolTip = action.label; button.setAccessibilityLabel(action.label)
            button.setAccessibilityIdentifier(action.id)
            button.contentTintColor = action.selected ? theme.blue : theme.workspaceMuted
            button.setAccessibilityValue(NSNumber(value: action.selected))
            button.isEnabled = action.enabled
            button.theme = theme; button.selected = action.selected; button.refresh()
        }
    }
    @objc private func invoke(_ button: NSButton) {
        guard actions.indices.contains(button.tag) else { return }
        actions[button.tag].perform()
    }
    override func layout() {
        super.layout()
        let leading: CGFloat = tile.documentID == nil ? 30 : 26
        var x = bounds.width - (tile.documentID == nil ? 12 : 14)
        for button in buttons.reversed() {
            button.isHidden = false
            if actions[button.tag].symbol == "xmark", tile.documentID != nil {
                let label = canvas?.model?.layout.openDocuments.count == 1 ? "원고 창 닫기" : "원고 객체 닫기"
                button.toolTip = label; button.setAccessibilityLabel(label)
            }
            let width: CGFloat = button.title.isEmpty ? 28 : ceil((button.title as NSString).size(withAttributes: [.font: button.font!]).width) + 12 + (button.image == nil ? 0 : 14)
            x -= width; button.frame = CGRect(x: x, y: 2, width: width, height: 28); x -= tile.documentID == nil ? 2 : 4
        }
        title.frame = CGRect(x: leading, y: 8, width: max(0, x - leading - 5), height: 18)
        let symbol: String? = switch tile { case .navigator: "folder"; case .characters: "person.2"; case .narrative: "arrow.triangle.branch"; case .margin: "sparkles"; case .document: nil; default: "square.grid.2x2" }
        icon.isHidden = symbol == nil
        icon.image = symbol.flatMap { WorkspaceIcons.image($0, size: 12) }
        icon.contentTintColor = theme.workspaceMuted; icon.frame = CGRect(x: 12, y: 10, width: 12, height: 12)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if tile.documentID != nil {
            (active ? theme.ink.withAlphaComponent(0.75) : theme.workspaceMuted.withAlphaComponent(0.25)).setFill()
            NSBezierPath(ovalIn: CGRect(x: 14, y: 13, width: 6, height: 6)).fill()
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in self?.canvas?.model?.pouchGeometryDidChange?() }
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { canvas?.beginPanelDrag(tile, event: event) }
    override func mouseDragged(with event: NSEvent) { canvas?.continuePanelDrag(event) }
    override func mouseUp(with event: NSEvent) { canvas?.finishPanelDrag(event) }
    override func cancelOperation(_ sender: Any?) { canvas?.cancelInteraction() }
    private var canvas: SpatialWorkspaceCanvasView? { enclosingSpatialCanvas }
    final class PassthroughTitle: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    final class PassthroughIcon: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension NSView {
    var enclosingSpatialCanvas: SpatialWorkspaceCanvasView? {
        var next: NSView? = self
        while let view = next {
            if let canvas = view as? SpatialWorkspaceCanvasView { return canvas }
            next = view.superview
        }
        return nil
    }
}
