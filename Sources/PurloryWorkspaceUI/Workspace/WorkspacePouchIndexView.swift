import AppKit

final class WorkspacePouchIndexView: NSView {
    weak var controller: WorkspacePouchIndexController?
    private let grip = WorkspacePouchIndexGrip(frame: .zero)
    private let scroll = NSScrollView()
    private let list = FlippedList()
    private let material = WorkspaceLiquidGlass.Surface()
    private let silhouette = CAShapeLayer()
    private let contour = CAShapeLayer()
    private var buttons: [WorkspaceHTMLButton] = []
    private var actions: [WorkspacePouchAction] = []
    private var geometry: WorkspacePouchIndexGeometry?
    private var theme = PurloryTheme.light
    private var progress: CGFloat = 0
    private var reduceTransparency = false
    private var materialTheme: PurloryTheme?
    private var materialOpaque: Bool?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = silhouette
        contour.fillColor = nil; contour.lineWidth = 1; contour.zPosition = 1
        layer?.addSublayer(contour)
        material.setAccessibilityIdentifier("purlory.workspace.pouch.index.material")
        addSubview(material)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("purlory.workspace.pouch.index"); setAccessibilityLabel("주머니")
        grip.target = self; grip.action = #selector(toggle)
        grip.image = WorkspaceIcons.image("grip-vertical", size: 16)
        grip.setAccessibilityIdentifier("purlory.writer-tools.compatibility")
        grip.setAccessibilityLabel("주머니 열기")
        grip.toolTip = "주머니 열기 · 드래그하여 펼치기"
        addSubview(grip)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.documentView = list; addSubview(scroll)
    }
    required init?(coder: NSCoder) { nil }

    func configure(theme: PurloryTheme, actions: [WorkspacePouchAction], reduceTransparency: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.theme = theme; self.actions = actions; grip.theme = theme; grip.index = controller; grip.refresh()
        contour.strokeColor = WorkspacePouchStyle.border(theme).cgColor
        updateMaterial()
        while buttons.count > actions.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < actions.count {
            let button = WorkspaceHTMLButton(frame: .zero)
            button.target = self; button.action = #selector(invoke(_:)); button.radius = 12
            list.addSubview(button); buttons.append(button)
        }
        for (i, action) in actions.enumerated() {
            let button = buttons[i]; button.tag = i; button.theme = theme
            button.image = WorkspaceIcons.image(action.symbol, size: 20)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            button.setAccessibilityIdentifier(action.id); button.setAccessibilityLabel(action.label)
            button.toolTip = action.label; button.isEnabled = action.enabled(); button.selected = action.selected()
            button.setAccessibilityValue(NSNumber(value: button.selected)); button.refresh()
        }
        needsLayout = true; needsDisplay = true
    }

    func update(geometry: WorkspacePouchIndexGeometry, progress: CGFloat, expanded: Bool) {
        self.geometry = geometry; self.progress = progress
        updateMaterial()
        grip.setAccessibilityLabel(expanded ? "주머니 접기" : "주머니 열기")
        grip.toolTip = expanded ? "주머니 접기 · Esc" : "주머니 열기 · 드래그하여 펼치기"
        grip.setAccessibilityValue(NSNumber(value: expanded))
        scroll.isHidden = progress < 0.8
        scroll.alphaValue = min(1, max(0, (progress - 0.8) / 0.2))
        needsLayout = true; needsDisplay = true; layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let geometry else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        material.frame = geometry.materialFrame; material.layoutSubtreeIfNeeded()
        silhouette.frame = bounds; silhouette.path = geometry.path.cgPath
        let edge = geometry.outerEdge
        if progress > 0.98 {
            edge.move(to: CGPoint(x: geometry.controlsMidX - 10, y: 72 + 5 * 52 + 2))
            edge.line(to: CGPoint(x: geometry.controlsMidX + 10, y: 72 + 5 * 52 + 2))
        }
        contour.frame = bounds; contour.path = edge.cgPath
        CATransaction.commit()
        let center = geometry.controlsMidX
        let gripWidth = min(44, geometry.exposedWidth)
        grip.frame = CGRect(x: center - gripWidth / 2, y: 8, width: gripWidth, height: 44)
        let listHeight = CGFloat(max(0, buttons.count - 1)) * 52 + 44 + 12
        list.frame = CGRect(x: 0, y: 0, width: 44, height: listHeight)
        scroll.frame = CGRect(x: center - 22, y: 72, width: 44, height: max(44, geometry.height - geometry.tail - 80))
        for (i, button) in buttons.enumerated() {
            button.frame = CGRect(x: 0, y: CGFloat(i) * 52 + (i == 5 ? 12 : 0), width: 44, height: 44)
        }
    }

    private func updateMaterial() {
        // An inward rail covers manuscript pixels. Use the shared opaque
        // fallback there instead of stacking glass over paper or window glass.
        let opaque = reduceTransparency || geometry?.opensInward == true
        guard materialTheme != theme || materialOpaque != opaque else { return }
        materialTheme = theme; materialOpaque = opaque
        material.configure(theme: theme, opaque: opaque)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard geometry?.path.contains(local) == true else { return nil }
        return super.hitTest(point)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea); super.updateTrackingAreas()
        addTrackingArea(.init(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { controller?.setHovered(true) }
    override func mouseExited(with event: NSEvent) { controller?.setHovered(false) }
    @objc private func toggle() { controller?.toggle() }
    @objc private func invoke(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag), actions[sender.tag].enabled() else { return }
        actions[sender.tag].perform()
    }
}

private final class FlippedList: NSView { override var isFlipped: Bool { true } }

private final class WorkspacePouchIndexGrip: WorkspaceHTMLButton {
    weak var index: WorkspacePouchIndexController?
    override func refresh() {
        super.refresh()
        // Lateral motion is the hover affordance; do not add a clipped capsule.
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func mouseDown(with event: NSEvent) { index?.beginDrag(at: screenX(event)) }
    override func mouseDragged(with event: NSEvent) { index?.updateDrag(to: screenX(event)) }
    override func mouseUp(with event: NSEvent) { index?.endDrag(at: screenX(event)) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func screenX(_ event: NSEvent) -> CGFloat {
        window?.convertPoint(toScreen: event.locationInWindow).x ?? event.locationInWindow.x
    }
}
