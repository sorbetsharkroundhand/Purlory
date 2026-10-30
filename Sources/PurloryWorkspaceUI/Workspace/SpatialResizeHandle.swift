import AppKit
import QuartzCore

enum SpatialResizeAxis: Equatable {
    case column(Int)
    case row(Int, Int)
}

final class SpatialResizeHandle: NSView {
    weak var canvas: SpatialWorkspaceCanvasView?
    var axis: SpatialResizeAxis = .column(0)
    var theme: PurloryTheme = .light
    private var hovered = false
    private var area: NSTrackingArea?
    private let indicator = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.addSublayer(indicator); indicator.opacity = 0
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformIncrement() -> Bool { adjust(1) }
    override func accessibilityPerformDecrement() -> Bool { adjust(-1) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 || event.keyCode == 125 { _ = adjust(1) }
        else if event.keyCode == 123 || event.keyCode == 126 { _ = adjust(-1) }
        else { super.keyDown(with: event) }
    }
    private func adjust(_ direction: Double) -> Bool {
        guard let canvas, let model = canvas.model, !model.isDragging else { return false }
        var layout = model.layout
        switch axis {
        case .column(let left):
            guard layout.columns.indices.contains(left + 1) else { return false }
            let rightFixed = layout.columns[left].width == nil && layout.columns[left + 1].width != nil
            let index = rightFixed ? left + 1 : left
            layout.setColumnWidth(index, width: (layout.columns[index].width ?? canvas.geometry.columns[index].width) + 16 * direction * (rightFixed ? -1 : 1))
        case .row(let column, let row):
            guard canvas.geometry.columns.indices.contains(column) else { return false }
            let height = canvas.geometry.columns[column].height
            layout.resizeRows(column: column, row: row, delta: height * 0.05 * direction, height: height)
        }
        model.setLayout(layout); canvas.layoutTiles(); return true
    }
    override func resetCursorRects() {
        let cursor: NSCursor
        if case .column = axis { cursor = .resizeLeftRight } else { cursor = .resizeUpDown }
        addCursorRect(bounds, cursor: cursor)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); self.area = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateIndicator(animated: true) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateIndicator(animated: true) }
    override func layout() { super.layout(); updateIndicator(animated: false) }
    private func updateIndicator(animated: Bool) {
        let rect: CGRect
        let length: CGFloat = hovered ? 42 : 28
        if case .column = axis { rect = CGRect(x: bounds.midX - 1, y: bounds.midY - length / 2, width: 2, height: length) }
        else { rect = CGRect(x: bounds.midX - length / 2, y: bounds.midY - 1, width: length, height: 2) }
        let path = CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)
        if animated && canvas?.reduceMotion != true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let shape = CABasicAnimation(keyPath: "path")
            shape.fromValue = indicator.presentation()?.path ?? indicator.path; shape.toValue = path
            shape.duration = 0.26; shape.timingFunction = WorkspaceHTMLStyle.calm
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = indicator.presentation()?.opacity ?? indicator.opacity; fade.toValue = hovered ? 1 : 0
            fade.duration = 0.22; fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            indicator.add(shape, forKey: "resize.length"); indicator.add(fade, forKey: "resize.opacity")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        indicator.path = path; indicator.fillColor = theme.ink2.cgColor; indicator.opacity = hovered ? 1 : 0
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, case .row(let column, let row) = axis, let model = canvas?.model {
            var layout = model.layout; layout.equalizeRows(column: column, row: row); model.setLayout(layout)
            canvas?.layoutTiles(); return
        }
        canvas?.beginResize(axis, event: event)
    }
    override func mouseDragged(with event: NSEvent) { canvas?.continueResize(event) }
    override func mouseUp(with event: NSEvent) { canvas?.finishResize() }
    override func cancelOperation(_ sender: Any?) { canvas?.cancelInteraction() }
}
