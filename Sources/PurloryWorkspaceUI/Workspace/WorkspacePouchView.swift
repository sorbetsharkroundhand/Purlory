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
    private struct ActionSnapshot: Equatable {
        let id: String
        let label: String
        let symbol: String
        let enabled: Bool
        let selected: Bool
    }

    private struct RenderedConfiguration: Equatable {
        let orb: Bool
        let horizontal: Bool
        let attached: Bool
        let theme: PurloryTheme
        let toolsExpanded: Bool
        let appearanceName: NSAppearance.Name?
        let controllerID: ObjectIdentifier?
        let actions: [ActionSnapshot]
    }

    weak var controller: WorkspacePouchController?
    private let grip = WorkspacePouchButton(title: "", target: nil, action: nil)
    private var buttons: [WorkspacePouchButton] = []
    private var actions: [WorkspacePouchAction] = []
    private var orb = false, horizontal = false, attached = false
    private var toolsHost: NSHostingView<AnyView>?
    private var pendingTools: AnyView?
    private var renderedConfiguration: RenderedConfiguration?
    var hasMountedToolsHost: Bool { toolsHost != nil }
    private(set) var toolsHostUpdateCount = 0
    private let dismissButton = WorkspacePouchButton(title: "", target: nil, action: nil)
    private let moreButton = WorkspacePouchButton(title: "", target: nil, action: nil)
    private let titleField = NSTextField(labelWithString: "Purlory")
    var targetTitle = "Purlory" {
        didSet {
            guard targetTitle != oldValue else { return }
            titleField.stringValue = targetTitle
            titleField.toolTip = targetTitle
        }
    }
    var placement: WorkspacePouchPlacement? { didSet { if placement != oldValue { needsLayout = true; needsDisplay = true } } }
    var toolsExpanded = false {
        didSet {
            guard toolsExpanded != oldValue else { return }
            if toolsExpanded, let pending = pendingTools {
                pendingTools = nil
                applyTools(pending)
            }
            needsLayout = true
            needsDisplay = true
        }
    }
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
        grip.isBordered = false; grip.refusesFirstResponder = false; grip.draggable = true; grip.buildsContextMenu = true
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
        if toolsExpanded {
            pendingTools = nil
            applyTools(root)
        } else {
            pendingTools = root
        }
    }

    private func applyTools(_ root: AnyView) {
        toolsHostUpdateCount += 1
        if let toolsHost {
            toolsHost.appearance = appearance
            toolsHost.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.setAccessibilityIdentifier("purlory.workspace.pouch.tools")
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

    @discardableResult
    func configure(orb: Bool, horizontal: Bool, actions: [WorkspacePouchAction], theme: PurloryTheme, attached: Bool = false) -> Bool {
        self.actions = actions
        let snapshots = actions.map {
            ActionSnapshot(id: $0.id, label: $0.label, symbol: $0.symbol, enabled: $0.enabled(), selected: $0.selected())
        }
        let nextConfig = RenderedConfiguration(
            orb: orb,
            horizontal: horizontal,
            attached: attached,
            theme: theme,
            toolsExpanded: toolsExpanded,
            appearanceName: appearance?.name,
            controllerID: controller.map(ObjectIdentifier.init),
            actions: snapshots
        )
        if renderedConfiguration == nextConfig { return false }

        let previous = renderedConfiguration
        let themeChanged = previous?.theme != theme
        let appearanceChanged = previous?.appearanceName != appearance?.name
        let modeChanged = previous == nil || previous?.orb != orb || previous?.attached != attached
        let gripChanged = previous == nil
            || modeChanged
            || themeChanged
            || previous?.toolsExpanded != toolsExpanded
            || previous?.controllerID != nextConfig.controllerID

        self.orb = orb; self.horizontal = horizontal; self.theme = theme; self.attached = attached
        if themeChanged {
            titleField.textColor = theme.ink
            moreButton.theme = theme; moreButton.refresh()
            dismissButton.theme = theme; dismissButton.refresh()
        }
        if appearanceChanged {
            toolsHost?.appearance = appearance
        }
        if gripChanged {
            grip.controller = controller
            grip.draggable = orb
            grip.title = orb ? "M" : ""
            if previous == nil || previous?.attached != attached {
                grip.image = attached ? WorkspaceIcons.image("slider.horizontal.3", size: 13) : nil
            }
            grip.theme = theme; grip.selected = orb || toolsExpanded
            grip.font = PurloryFonts.serif(12, weight: .bold); grip.refresh()
            if modeChanged {
                grip.setAccessibilityIdentifier(orb ? "purlory.workspace.pouch.restore" : "purlory.workspace.pouch.legacy-grip")
                grip.setAccessibilityHidden(attached)
                grip.setAccessibilityLabel(orb ? "Purlory 전체 창 펼치기" : "주머니 펼치기")
                grip.toolTip = orb ? "클릭하여 원고 펼치기 · 드래그하여 이동" : "주머니 펼치기"
            }
        }
        while buttons.count > actions.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < actions.count {
            let button = WorkspacePouchButton(title: "", target: self, action: #selector(invoke(_:)))
            button.refusesFirstResponder = false
            buttons.append(button); addSubview(button)
        }
        let previousActions = previous?.actions ?? []
        for (index, action) in actions.enumerated() {
            let button = buttons[index]
            let snapshot = snapshots[index]
            let previousAction = index < previousActions.count ? previousActions[index] : nil
            button.controller = controller; button.tag = index
            button.isHidden = orb || attached
            if previousAction == nil || themeChanged || previousAction?.id != snapshot.id || previousAction?.label != snapshot.label || previousAction?.symbol != snapshot.symbol {
                if previousAction?.symbol != snapshot.symbol {
                    button.image = WorkspaceIcons.image(action.symbol, size: 14)
                }
                button.title = ""
                if previousAction?.id != snapshot.id { button.setAccessibilityIdentifier(action.id) }
                if previousAction?.label != snapshot.label {
                    button.setAccessibilityLabel(action.label)
                    button.toolTip = action.label
                }
                button.theme = theme
            }
            if previousAction == nil || themeChanged || previousAction?.enabled != snapshot.enabled || previousAction?.selected != snapshot.selected {
                button.isEnabled = snapshot.enabled
                button.selected = snapshot.selected
                button.setAccessibilityValue(NSNumber(value: snapshot.selected))
                button.refresh()
            }
        }
        renderedConfiguration = nextConfig
        needsLayout = true; needsDisplay = true
        return true
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
    var buildsContextMenu = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? {
        buildsContextMenu ? (controller?.moreMenu() ?? super.menu(for: event)) : super.menu(for: event)
    }
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

/// A geometry-only anchor for detail cards; the visible entry lives on the window edge.
struct WorkspacePouchTrigger: NSViewRepresentable {
    @Bindable var model: SpatialWorkspaceController
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
        button.alphaValue = 0
        button.setAccessibilityElement(false); button.setAccessibilityHidden(true)
        button.setAccessibilityIdentifier("purlory.workspace.pouch.anchor")
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
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    @Bindable var model: SpatialWorkspaceController
    let requests: ProjectEditorRequests
    let defaults: UserDefaults
    let theme: PurloryTheme
    let tools: AnyView
    var targetTitle = "Purlory"
    let actions: [WorkspacePouchAction]
    let indexActions: [WorkspacePouchAction]
    let extraActions: [WorkspacePouchAction]
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.purloryWorkspaceAccessibilityOptions) private var accessibilityOptions

    func makeCoordinator() -> Coordinator { Coordinator(model: model, defaults: defaults) }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.coordinator = context.coordinator; view.controller = context.coordinator.controller
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        context.coordinator.update(
            window: view.window,
            view: view,
            reduceMotion: accessibilityOptions.resolvedReduceMotion(system: systemReduceMotion),
            accessibilityOptions: accessibilityOptions,
            reduceTransparency: systemReduceTransparency || accessibilityOptions.reduceTransparency,
            theme: theme,
            actions: actions,
            indexActions: indexActions,
            extraActions: extraActions,
            targetTitle: targetTitle,
            requests: requests,
            tools: tools
        )
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) {
        coordinator.controller.detachFromWorkspaceView(view)
        view.coordinator = nil; view.controller = nil
    }
    @MainActor final class Coordinator {
        private(set) var controller: WorkspacePouchController
        init(model: SpatialWorkspaceController, defaults: UserDefaults) { controller = WorkspacePouchController(model: model, defaults: defaults) }
        func attach(to window: NSWindow, from view: Probe) {
            adoptControllerIfNeeded(for: window, from: view)
            controller.attach(to: window, from: view)
        }
        func update(
            window: NSWindow?,
            view: Probe,
            reduceMotion: Bool,
            accessibilityOptions: WorkspaceAccessibilityOptions,
            reduceTransparency: Bool,
            theme: PurloryTheme,
            actions: [WorkspacePouchAction],
            indexActions: [WorkspacePouchAction],
            extraActions: [WorkspacePouchAction],
            targetTitle: String,
            requests: ProjectEditorRequests,
            tools: AnyView
        ) {
            if let window {
                adoptControllerIfNeeded(for: window, from: view)
            }
            controller.applyBridgeUpdate(
                window: window,
                workspaceView: view,
                reduceMotion: reduceMotion,
                accessibilityOptions: accessibilityOptions,
                reduceTransparency: reduceTransparency,
                theme: theme,
                actions: actions,
                indexActions: indexActions,
                extraActions: extraActions,
                targetTitle: targetTitle,
                requests: requests,
                tools: tools
            )
            requests.pouch = controller
        }
        private func adoptControllerIfNeeded(for window: NSWindow, from view: Probe) {
            if let retained = WorkspacePouchLifetime.controller(for: window), retained !== controller {
                controller.detachFromWorkspaceView(view)
                controller = retained
            }
            view.controller = controller
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
