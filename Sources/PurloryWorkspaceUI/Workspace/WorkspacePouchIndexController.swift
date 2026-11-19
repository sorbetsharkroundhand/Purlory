import AppKit

/// A presentation-only child window: opening tools never reflows the manuscript.
@MainActor final class WorkspacePouchIndexController {
    let panel: NSPanel
    let view = WorkspacePouchIndexView()
    private weak var parent: NSWindow?
    private(set) var isExpanded = false
    private(set) var geometry: WorkspacePouchIndexGeometry?
    var reduceMotion = false
    var reduceTransparency = false
    var onClose: (() -> Void)?
    var animationTime: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var expansion = WorkspaceSpringValue(value: 0)
    private var hover = WorkspaceSpringValue(value: 0)
    private var hovered = false
    private var clock: WorkspaceDisplayClock?
    private var updated = 0.0
    private var drag: (x: CGFloat, progress: CGFloat, direction: CGFloat)?
    private var dragged = false

    init(parent: NSWindow) {
        self.parent = parent
        panel = IndexPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = true; panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false; panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view; view.controller = self
        parent.addChildWindow(panel, ordered: .above)
    }

    @discardableResult
    func update(theme: PurloryTheme, actions: [WorkspacePouchAction], visible: Bool) -> Bool {
        var changed = view.configure(theme: theme, actions: actions, reduceTransparency: reduceTransparency)
        let appearanceName: NSAppearance.Name = theme.editorSurface.relativeLuminance < 0.5 ? .darkAqua : .aqua
        if panel.appearance?.name != appearanceName {
            panel.appearance = NSAppearance(named: appearanceName)
            changed = true
        }
        guard visible, parent?.isVisible == true, parent?.isMiniaturized == false,
              parent?.attachedSheet == nil else {
            if panel.isVisible || drag != nil || hovered || clock != nil || expansion.value != (isExpanded ? 1 : 0) || hover.value != 0 {
                hide()
                changed = true
            }
            return changed
        }
        if reduceMotion { settle() }
        if layout() { changed = true }
        // AppKit removes the child relationship when a panel is ordered out.
        if panel.parent !== parent { parent?.addChildWindow(panel, ordered: .above); changed = true }
        if !panel.isVisible { panel.orderFront(nil); changed = true }
        return changed
    }

    @discardableResult
    func layout() -> Bool {
        guard let parent else { return false }
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame.insetBy(dx: -100, dy: 0)
        let geometry = WorkspacePouchIndexGeometry(window: parent.frame, screen: screen,
                                                   progress: expansion.value, hover: hover.value)
        if self.geometry == geometry,
           panel.frame == geometry.frame,
           view.matches(geometry: geometry, progress: expansion.value, expanded: isExpanded) {
            return false
        }
        self.geometry = geometry
        if panel.frame != geometry.frame {
            panel.setFrame(geometry.frame, display: false)
        }
        view.update(geometry: geometry, progress: expansion.value, expanded: isExpanded)
        return true
    }

    func setExpanded(_ expanded: Bool) {
        let wasExpanded = isExpanded
        isExpanded = expanded
        if wasExpanded && !expanded { onClose?() }
        animate()
    }
    func toggle() { setExpanded(!isExpanded) }
    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value; animate()
    }
    private func animate() {
        if reduceMotion {
            stopAnimation(); expansion = .init(value: isExpanded ? 1 : 0); hover = .init(value: 0)
            layout(); return
        }
        guard drag == nil, clock == nil else { return }
        updated = animationTime()
        clock = WorkspaceDisplayClock(view: view) { [weak self] in
            guard let self else { return false }
            self.stepAnimation(); return self.clock != nil
        }
    }
    func stepAnimation() {
        let now = animationTime(), elapsed = now - updated; updated = now
        let target: CGFloat = isExpanded ? 1 : 0, hoverTarget: CGFloat = hovered && !isExpanded ? 1 : 0
        expansion.advance(to: target, elapsed: elapsed)
        hover.advance(to: hoverTarget, elapsed: elapsed)
        if expansion.isSettled(at: target, valueTolerance: 0.001, velocityTolerance: 0.01),
           hover.isSettled(at: hoverTarget, valueTolerance: 0.001, velocityTolerance: 0.01) {
            expansion = .init(value: target); hover = .init(value: hoverTarget); stopAnimation()
        }
        layout()
    }

    func beginDrag(at x: CGFloat) {
        stopAnimation(); dragged = false
        drag = (x, expansion.value, geometry?.opensInward == true ? -1 : 1)
    }
    func updateDrag(to x: CGFloat) {
        guard let drag else { return }
        let delta = (x - drag.x) * drag.direction
        guard dragged || abs(delta) >= 6 else { return }
        dragged = true
        expansion = .init(value: min(1, max(0, drag.progress + delta / WorkspacePouchIndexGeometry.travel)))
        hover = .init(value: 0); layout()
    }
    func endDrag(at x: CGFloat) {
        guard drag != nil else { return }
        updateDrag(to: x); drag = nil
        if dragged { setExpanded(expansion.value >= 0.5) } else { toggle() }
    }
    func detach() {
        stopAnimation(); drag = nil
        parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close(); parent = nil
    }
    func hide() {
        panel.orderOut(nil); drag = nil; hovered = false; settle()
    }
    private func settle() {
        stopAnimation(); expansion = .init(value: isExpanded ? 1 : 0); hover = .init(value: 0)
    }
    private func stopAnimation() { clock?.invalidate(); clock = nil }
}

private final class IndexPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
