import AppKit
import SwiftUI

enum WorkspacePouchStyle {
    static let width: CGFloat = 304
    static let radius: CGFloat = 15
    static let bodyInsets: CGFloat = 54
    static let shadowInset: CGFloat = 28
    static func surface(_ theme: PurloryTheme) -> NSColor { theme.pill.withAlphaComponent(1) }
    static func border(_ theme: PurloryTheme) -> NSColor {
        theme.ink.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.3 : 0.10)
    }
}

final class WorkspacePouchView: NSView {
    weak var controller: WorkspacePouchController?
    private let grip = WorkspacePouchButton(title: "", target: nil, action: nil)
    private var buttons: [WorkspacePouchButton] = []
    private var actions: [WorkspacePouchAction] = []
    private var orb = false, horizontal = false, attached = false
    private var toolsHost: NSHostingView<AnyView>?
    private let dismissButton = WorkspacePouchButton(title: "", target: nil, action: nil)
    private let moreButton = WorkspacePouchButton(title: "", target: nil, action: nil)
    private let titleField = NSTextField(labelWithString: "Purlory")
    var targetTitle = "Purlory" { didSet { titleField.stringValue = targetTitle; titleField.toolTip = targetTitle } }
    var placement: WorkspacePouchPlacement? { didSet { if placement != oldValue { needsLayout = true; needsDisplay = true } } }
    var toolsExpanded = false { didSet { needsLayout = true; needsDisplay = true } }
    private var theme: PurloryTheme = .light
    private(set) var hovered = false
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        grip.target = self; grip.action = #selector(activateGrip)
        grip.isBordered = false; grip.refusesFirstResponder = false; grip.draggable = true
        addSubview(grip)
        titleField.font = PurloryFonts.ui(12, weight: .semibold)
        titleField.textColor = theme.ink
        titleField.lineBreakMode = .byTruncatingTail; titleField.maximumNumberOfLines = 1
        titleField.setAccessibilityIdentifier("purlory.workspace.pouch.title")
        addSubview(titleField)
        for (button, symbol, label, identifier, selector) in [
            (moreButton, "ellipsis", "모든 도구", "purlory.workspace.pouch.more", #selector(showMore)),
            (dismissButton, "xmark", "주머니 닫기 · Esc", "purlory.workspace.pouch.dismiss", #selector(dismissTools))
        ] {
            button.target = self; button.action = selector
            button.image = WorkspaceIcons.image(symbol, size: 12)
            button.refusesFirstResponder = false
            button.theme = theme; button.refresh()
            button.setAccessibilityIdentifier(identifier); button.setAccessibilityLabel(label)
            button.toolTip = label; addSubview(button)
        }
    }
    required init?(coder: NSCoder) { nil }

    func setTools(_ root: AnyView) {
        if let toolsHost { toolsHost.rootView = root }
        else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []; host.wantsLayer = true
            host.frame = CGRect(x: 0, y: 0, width: WorkspacePouchStyle.width - 12, height: 1)
            host.appearance = appearance
            addSubview(host, positioned: .below, relativeTo: dismissButton); toolsHost = host
        }
        needsLayout = true
    }
    func clearPressedState() { grip.highlight(false) }
    func revealTools(reduceMotion: Bool) {
        guard !reduceMotion, let layer = toolsHost?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7; fade.toValue = 1; fade.duration = 0.08
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "pouch.reveal")
    }
    func hideToolsImmediately() {
        toolsHost?.layer?.removeAllAnimations()
        toolsHost?.isHidden = true; dismissButton.isHidden = true
        moreButton.isHidden = true; titleField.isHidden = true
        toolsExpanded = false
        needsDisplay = true
    }
    var toolsOwnFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder.isDescendant(of: self), responder !== grip { return true }
        return ((responder as? NSTextView)?.delegate as? NSView)?.isDescendant(of: self) == true
    }

    func configure(orb: Bool, horizontal: Bool, actions: [WorkspacePouchAction], theme: PurloryTheme, attached: Bool = false) {
        self.orb = orb; self.horizontal = horizontal; self.actions = actions; self.theme = theme; self.attached = attached
        titleField.textColor = theme.ink
        moreButton.theme = theme; moreButton.refresh()
        dismissButton.theme = theme; dismissButton.refresh()
        toolsHost?.appearance = appearance
        grip.controller = controller
        grip.draggable = orb
        grip.title = orb ? "M" : ""
        grip.image = attached ? WorkspaceIcons.image("slider.horizontal.3", size: 13) : nil
        grip.theme = theme; grip.selected = orb || toolsExpanded
        grip.font = PurloryFonts.serif(12, weight: .bold); grip.refresh()
        grip.setAccessibilityIdentifier(orb ? "purlory.workspace.pouch.restore" : "purlory.writer-tools.compatibility")
        grip.setAccessibilityLabel(orb ? "Purlory 전체 창 펼치기" : "주머니 펼치기")
        grip.toolTip = orb ? "클릭하여 원고 펼치기 · 드래그하여 이동" : "주머니 펼치기"
        grip.menu = controller?.moreMenu()
        while buttons.count > actions.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < actions.count {
            let button = WorkspacePouchButton(title: "", target: self, action: #selector(invoke(_:)))
            button.refusesFirstResponder = false
            buttons.append(button); addSubview(button)
        }
        for (index, action) in actions.enumerated() {
            let button = buttons[index]; button.controller = controller; button.tag = index
            button.isHidden = orb || attached
            button.image = WorkspaceIcons.image(action.symbol, size: 14)
            button.title = ""; button.isEnabled = action.enabled()
            button.theme = theme; button.selected = action.selected(); button.refresh()
            button.setAccessibilityIdentifier(action.id); button.setAccessibilityLabel(action.label)
            button.setAccessibilityValue(NSNumber(value: action.selected())); button.toolTip = action.label
        }
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        let expanded = attached && toolsExpanded && placement?.card.isEmpty == false
        setAccessibilityElement(!attached || expanded)
        toolsHost?.isHidden = !expanded; dismissButton.isHidden = !expanded
        moreButton.isHidden = !expanded; titleField.isHidden = !expanded
        if attached, let placement {
            grip.isHidden = true
            grip.frame = placement.trigger
            if expanded {
                let card = placement.card
                titleField.frame = CGRect(x: card.minX + 16, y: card.minY + 15, width: max(0, card.width - 94), height: 18)
                moreButton.frame = CGRect(x: card.maxX - 66, y: card.minY + 10, width: 28, height: 28)
                dismissButton.frame = CGRect(x: card.maxX - 36, y: card.minY + 10, width: 28, height: 28)
                toolsHost?.frame = CGRect(x: card.minX + 6, y: card.minY + 46, width: max(0, card.width - 12), height: max(0, card.height - 54))
            }
            return
        }
        grip.isHidden = false
        if orb { grip.frame = bounds; return }
        grip.frame = horizontal ? CGRect(x: 4, y: 5, width: 12, height: 28) : CGRect(x: 5, y: 3, width: 28, height: 12)
        var position: CGFloat = 18
        for (index, button) in buttons.enumerated() {
            if index == 4 { position += 12 }
            button.frame = horizontal ? CGRect(x: position, y: 5, width: 28, height: 28)
                : CGRect(x: 5, y: position, width: 28, height: 28)
            position += 32
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if attached, let placement {
            if toolsExpanded, !placement.card.isEmpty {
                let card = NSBezierPath(roundedRect: placement.card.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: WorkspacePouchStyle.radius, yRadius: WorkspacePouchStyle.radius)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowBlurRadius = PurloryElevation.floating.radius
                shadow.shadowOffset = CGSize(width: 0, height: -PurloryElevation.floating.y)
                shadow.shadowColor = NSColor.black.withAlphaComponent(theme.editorSurface.relativeLuminance < 0.5 ? 0.28 : PurloryElevation.floating.opacity)
                shadow.set()
                WorkspacePouchStyle.surface(theme).setFill(); card.fill()
                NSGraphicsContext.restoreGraphicsState()
                WorkspacePouchStyle.border(theme).setStroke(); card.lineWidth = 1; card.stroke()
            }
            return
        }
        theme.pill.withAlphaComponent(1).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: orb ? 14 : 12, yRadius: orb ? 14 : 12)
        shape.fill(); theme.pillBorder.setStroke(); shape.stroke()
        if orb { return }
        theme.workspaceMuted.withAlphaComponent(0.6).setFill()
        let handle = horizontal ? CGRect(x: 8, y: 12, width: 3, height: 14) : CGRect(x: 12, y: 7, width: 14, height: 3)
        NSBezierPath(roundedRect: handle, xRadius: 1.5, yRadius: 1.5).fill()
    }
    func containsControl(at point: CGPoint) -> Bool {
        guard attached, let placement else { return bounds.contains(point) }
        if toolsExpanded, placement.card.contains(point) { return true }
        return false
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsControl(at: convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    override func accessibilityFrame() -> NSRect {
        guard attached, let placement, let window else { return super.accessibilityFrame() }
        let area = toolsExpanded ? placement.card : .zero
        return window.convertToScreen(convert(area, to: nil))
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea); super.updateTrackingAreas()
        let area = attached ? (placement?.trigger ?? bounds) : bounds
        addTrackingArea(.init(rect: area, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; controller?.refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; controller?.refresh() }
    @objc private func activateGrip() {
        if orb { controller?.restore() } else { controller?.toggleTools() }
    }
    @objc private func invoke(_ button: NSButton) {
        guard actions.indices.contains(button.tag) else { return }
        actions[button.tag].perform(); controller?.refresh()
    }
    @objc private func dismissTools() { controller?.dismissTools() }
    @objc private func showMore() { controller?.showMoreMenu(in: moreButton) }
    override func mouseDown(with event: NSEvent) {
        if !attached { controller?.beginDrag(at: screenPoint(event)) }
    }
    override func mouseDragged(with event: NSEvent) { controller?.updateDrag(to: screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { _ = controller?.endDrag(at: screenPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { controller?.showMoreMenu(in: self) }
    override func resetCursorRects() { if !grip.isHidden { addCursorRect(grip.frame, cursor: .openHand) } }
    private func screenPoint(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow }
}

final class WorkspacePouchButton: WorkspaceHTMLButton {
    weak var controller: WorkspacePouchController?
    var draggable = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        guard draggable else { super.mouseDown(with: event); return }
        highlight(true); controller?.beginDrag(at: screenPoint(event), from: self)
    }
    override func mouseDragged(with event: NSEvent) {
        if draggable { controller?.updateDrag(to: screenPoint(event)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard draggable else { super.mouseUp(with: event); return }
        highlight(false)
        if controller?.endDrag(at: screenPoint(event)) != true { performClick(nil) }
    }
    override func highlight(_ flag: Bool) { super.highlight(flag); refresh() }
    override func refresh() {
        super.refresh()
        let active = selected || isHighlighted
        layer?.backgroundColor = (active ? theme.ink.withAlphaComponent(0.08) : (hovered ? theme.hover : .clear)).cgColor
        contentTintColor = isEnabled ? theme.ink : theme.ink2
        if !title.isEmpty {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? PurloryFonts.ui(11, weight: .medium),
                .foregroundColor: isEnabled ? theme.ink : theme.ink2
            ])
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func screenPoint(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow }
}

/// The only normal-mode pouch entry point; dragging it never moves or folds a window.
struct WorkspacePouchTrigger: NSViewRepresentable {
    @ObservedObject var model: SpatialWorkspaceController
    let theme: PurloryTheme
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> Trigger {
        let button = Trigger(frame: .zero)
        button.target = context.coordinator; button.action = #selector(Coordinator.open)
        button.refusesFirstResponder = true
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = WorkspaceIcons.image("slider.horizontal.3", size: 14)
        button.setAccessibilityIdentifier("purlory.writer-tools.compatibility")
        button.setAccessibilityLabel("주머니 열기")
        button.toolTip = "집필 도구 · 조판 · 로컬 AI"
        button.geometryChanged = { [weak model] in model?.pouchGeometryDidChange?() }
        model.pouchAnchor = button
        return button
    }
    func updateNSView(_ button: Trigger, context: Context) {
        model.pouchAnchor = button
        button.title = ""
        button.imagePosition = .imageOnly
        button.theme = theme; button.selected = model.pouchSection != nil; button.refresh()
        button.setAccessibilityValue(NSNumber(value: button.selected))
    }
    final class Trigger: WorkspaceHTMLButton {
        var geometryChanged: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.geometryChanged?() }
        }
    }
    @MainActor final class Coordinator: NSObject {
        let model: SpatialWorkspaceController
        init(_ model: SpatialWorkspaceController) { self.model = model }
        @objc func open() { model.whisperTyping = false; model.pouchController?.toggleTools() }
    }
}

struct WorkspacePouchBridge: NSViewRepresentable {
    @ObservedObject var model: SpatialWorkspaceController
    let requests: ProjectEditorRequests
    let defaults: UserDefaults
    let theme: PurloryTheme
    let tools: AnyView
    var targetTitle = "Purlory"
    let actions: [WorkspacePouchAction]
    let extraActions: [WorkspacePouchAction]
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.purloryWorkspaceAccessibilityOptions) private var accessibilityOptions

    func makeCoordinator() -> Coordinator { Coordinator(model: model, defaults: defaults) }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.coordinator = context.coordinator; view.controller = context.coordinator.controller
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        if let window = view.window { context.coordinator.attach(to: window, from: view) }
        let controller = context.coordinator.controller
        controller.reduceMotion = accessibilityOptions.resolvedReduceMotion(system: systemReduceMotion)
        controller.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || accessibilityOptions.reduceTransparency
        controller.theme = theme; controller.actions = actions; controller.extraActions = extraActions
        controller.targetTitle = targetTitle
        controller.requests = requests
        controller.setTools(tools)
        requests.pouch = controller
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) {
        coordinator.controller.detachFromWorkspaceView(view)
        view.coordinator = nil; view.controller = nil
    }
    @MainActor final class Coordinator {
        private(set) var controller: WorkspacePouchController
        init(model: SpatialWorkspaceController, defaults: UserDefaults) { controller = WorkspacePouchController(model: model, defaults: defaults) }
        func attach(to window: NSWindow, from view: Probe) {
            if let retained = WorkspacePouchLifetime.controller(for: window), retained !== controller {
                controller.detachFromWorkspaceView(view)
                controller = retained
            }
            view.controller = controller
            controller.attach(to: window, from: view)
        }
    }
    final class Probe: NSView {
        weak var coordinator: Coordinator?
        weak var controller: WorkspacePouchController?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.attach(to: window, from: self) }
            else { controller?.detachFromWorkspaceView(self) }
        }
    }
}
