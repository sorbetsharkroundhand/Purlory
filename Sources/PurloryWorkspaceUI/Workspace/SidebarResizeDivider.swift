import AppKit
import SwiftUI

/// 사이드바-에디터 사이 커스텀 분할 divider — 근접 감지·확대 히트영역·리사이즈 커서.
///
/// **왜 AppKit(NSViewRepresentable)인가.** SwiftUI의 `.onHover`는 히트테스트에
/// 참여하는 뷰에서만 발동하므로 "넓은 근접존이 hover는 감지하되 클릭은 가로채지
/// 않는다"를 표현할 수 없다. NSTrackingArea(마우스 이동 감지)와 hitTest(클릭
/// 가로채기)는 서로 독립적이라, 이 둘을 분리하면 idle에서 넓은 존이 아무
/// interaction도 삼키지 않게 만들 수 있다.
///
/// 상태: idle(얇은 선 + ±3pt 히트) → pointerNear(굵은 선 + ±9pt 히트 + resize
/// 커서) → dragging(near 유지 + 실시간 리사이즈). 근접 감지 트래킹 영역(±12pt)은
/// 상태와 무관하게 고정 크기라, 히트영역이 확대되는 순간 hover가 풀리는
/// flickering이 생기지 않는다.
struct SidebarResizeDivider: NSViewRepresentable {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let collapseThreshold: CGFloat
    let collapseReleaseThreshold: CGFloat
    let onCollapse: () -> Void
    let onDragPreview: (CGFloat?) -> Void
    let onDragSettled: () -> Void
    let theme: PurloryTheme

    func makeNSView(context: Context) -> DividerHandleView {
        let view = DividerHandleView()
        configure(view)
        return view
    }

    func updateNSView(_ view: DividerHandleView, context: Context) {
        configure(view)
    }

    private func configure(_ view: DividerHandleView) {
        view.minWidth = minWidth
        view.maxWidth = maxWidth
        view.collapseThreshold = collapseThreshold
        view.collapseReleaseThreshold = collapseReleaseThreshold
        view.onCollapse = onCollapse
        view.onDragPreview = onDragPreview
        view.onDragSettled = onDragSettled
        // idle 선은 그리지 않는다 — 사이드바가 이미 우측에 1px sep을 그려
        // 경계에 얇은 선이 있다. near/dragging에서만 굵은 선을 덧그린다.
        view.idleLineColor = .clear
        view.nearLineColor = theme.ink3
        // Binding은 매 업데이트마다 최신값을 읽도록 클로저로 감싼다.
        view.currentWidth = { width }
        view.onWidthChange = { newWidth in width = newWidth }
    }
}

/// SidebarResizeDivider의 실제 AppKit 뷰. 좌표 x만 다루므로 flipped 여부는 무관.
///
/// 접근성 (#59): 마우스 드래그 전용이던 너비 조절을 **조절 가능(adjustable) AX
/// 요소**로 노출한다 — VoiceOver 스와이프·Full Keyboard Access 방향키로 ±20pt.
final class DividerHandleView: NSView {
    var onWidthChange: ((CGFloat) -> Void)?
    var currentWidth: (() -> CGFloat)?
    var minWidth: CGFloat = 200
    var maxWidth: CGFloat = 360
    var collapseThreshold: CGFloat = 150
    var collapseReleaseThreshold: CGFloat = 176
    var onCollapse: (() -> Void)?
    var onDragPreview: ((CGFloat?) -> Void)?
    var onDragSettled: (() -> Void)?

    // NSAccessibility 프로토콜 위트니스 중 상위에 선언이 있는 것(isAccessibility·
    // Role·Label)만 override이고, 값·증감(NSAccessibilityValue/Incrementor
    // 프로토콜 기본 구현)은 키워드 없이 대체한다.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "사이드바 너비" }
    override func accessibilityValue() -> Any? {
        Int(currentWidth?() ?? 0)
    }
    // 증감은 NSAccessibilityIncrementor/Decrementor 프로토콜 기본 구현 대체 —
    // 상위 클래스 선언이 없어 override 키워드를 쓰지 않는다.
    func accessibilityIncrement() {
        adjust(by: 20)
    }
    func accessibilityDecrement() {
        if (currentWidth?() ?? minWidth) <= minWidth + 0.5, let onCollapse {
            onCollapse()
            NSAccessibility.post(element: self, notification: .valueChanged)
            return
        }
        adjust(by: -20)
    }

    private func adjust(by delta: CGFloat) {
        guard let onWidthChange else { return }
        let next = min(max((currentWidth?() ?? 0) + delta, minWidth), maxWidth)
        onWidthChange(next)
        // 값 변화를 VoiceOver에 알린다 — 슬라이더 규약 (요구사항 §33의 로컬 원칙).
        NSAccessibility.post(
            element: self, notification: .valueChanged)
    }
    var idleLineColor: NSColor = .clear { didSet { needsDisplay = true } }
    var nearLineColor: NSColor = .clear { didSet { needsDisplay = true } }

    /// 확대 히트영역 반폭 — near/dragging에서 여기까지 클릭을 잡고 resize 커서.
    private let expandedHalf: CGFloat = 9
    /// idle 히트영역 반폭 — 평상시엔 이 얇은 대역만 claim(나머지는 통과).
    private let idleHalf: CGFloat = 3

    private enum State { case idle, near, dragging }
    private var state: State = .idle {
        didSet { if oldValue != state { needsDisplay = true } }
    }
    private var isActive: Bool { state != .idle }

    private var trackingArea: NSTrackingArea?
    private var dragStartMouseX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0
    private var collapseArmed = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        // 근접 감지는 뷰 전체(±12pt) 고정 — 상태에 따라 크기가 바뀌지 않으므로
        // enter/exit이 재발화되며 깜빡이지 않는다.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // idle에선 ±3pt만, near/dragging에선 ±9pt만 claim한다. 그 밖의 점은 nil을
    // 반환해 아래 패널(사이드바·에디터)로 클릭이 통과한다 — 넓은 존이 평상시
    // 다른 interaction을 가로채지 않게 하는 핵심.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let half = isActive ? expandedHalf : idleHalf
        return abs(local.x - bounds.midX) <= half ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        if state != .dragging { state = .near }
        updateCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard state != .dragging else { return }
        state = .near
        updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        // 드래그 중엔 존을 벗어나도 상태를 유지한다 — mouseUp에서 정리.
        guard state != .dragging else { return }
        state = .idle
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        state = .dragging
        dragStartMouseX = event.locationInWindow.x
        dragStartWidth = currentWidth?() ?? bounds.width
        collapseArmed = false
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard state == .dragging else { return }
        // 드래그가 존을 벗어나도 mouseUp까지 이벤트가 이 뷰로 계속 라우팅된다.
        let dx = event.locationInWindow.x - dragStartMouseX
        let projectedWidth = dragStartWidth + dx
        if collapseArmed {
            collapseArmed = projectedWidth < collapseReleaseThreshold
        } else {
            collapseArmed = projectedWidth <= collapseThreshold
        }
        NSCursor.resizeLeftRight.set()
        if projectedWidth < minWidth {
            onDragPreview?(max(0, projectedWidth))
        } else {
            onDragPreview?(nil)
            onWidthChange?(min(maxWidth, projectedWidth))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if collapseArmed {
            // Dragging through the collapse threshold is a visibility gesture, not a
            // request to overwrite the user's preferred expanded width. Restore the
            // drag-start width before hiding so the next reopen returns to that width.
            let restored = max(minWidth, min(maxWidth, dragStartWidth))
            onWidthChange?(restored)
            collapseArmed = false
            onCollapse?()
        } else {
            onDragSettled?()
        }
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) {
            state = .near
            updateCursor(for: event)
        } else {
            state = .idle
            NSCursor.arrow.set()
        }
    }

    /// 확대 히트영역(±9pt) 안에서만 resize 커서 — 감지존 바깥 테두리(9~12pt)는
    /// 선만 굵어지고 커서는 기본이라 "잡을 수 있는 곳"이 커서로 정직하게 드러난다.
    private func updateCursor(for event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if abs(local.x - bounds.midX) <= expandedHalf {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = isActive ? 3 : 1
        let color = isActive ? nearLineColor : idleLineColor
        guard color.alphaComponent > 0 else { return }
        color.setFill()
        NSRect(
            x: bounds.midX - lineWidth / 2, y: 0,
            width: lineWidth, height: bounds.height
        ).fill()
    }
}
