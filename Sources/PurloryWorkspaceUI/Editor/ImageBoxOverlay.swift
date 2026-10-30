import AppKit

/// 선택된 이미지를 감싸는 오버레이 박스 — 이미지를 "하나의 박스"로 다루기 위한 뷰.
///
/// 텍스트 뷰(BlockTextView) 위에 서브뷰로 얹혀, 텍스트 히트 판정·I-beam 커서에
/// 방해받지 않고 자기 마우스·커서를 직접 처리한다:
/// - 네 모서리 핸들 드래그 → 원본 비율 유지하며 크기 조절 (요구 A)
/// - 몸통 드래그 → 문서 내 다른 줄로 이동 (요구 B)
final class ImageBoxOverlay: NSView {
    private weak var textView: BlockTextView?
    /// 감싸고 있는 이미지 문단의 시작 위치.
    var paraLocation: Int = 0
    var theme: PurloryTheme

    /// 핸들 한 변(pt)과, 핸들이 프레임 밖으로 삐져나오지 않도록 두는 여유.
    private let handle: CGFloat = 12
    var inset: CGFloat { handle / 2 + 2 }

    private enum Corner: CaseIterable { case tl, tr, bl, br }
    private enum Drag { case none, resize(Corner), move }
    private var drag: Drag = .none
    private var startWinPoint: NSPoint = .zero
    private var startWidth: Int = 100
    private var didMove = false

    override var isFlipped: Bool { true }

    init(textView: BlockTextView, theme: PurloryTheme) {
        self.textView = textView
        self.theme = theme
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    /// 이미지가 실제로 그려지는 영역(오버레이 좌표계) — 프레임에서 inset만큼 안쪽.
    private var imageRect: NSRect { bounds.insetBy(dx: inset, dy: inset) }

    // MARK: 그리기 — 테두리 + 네 모서리 핸들

    override func draw(_ dirtyRect: NSRect) {
        let box = imageRect
        let border = NSBezierPath(
            roundedRect: box.insetBy(dx: -2, dy: -2), xRadius: 6, yRadius: 6)
        border.lineWidth = 2
        theme.blue.setStroke()
        border.stroke()
        for c in Corner.allCases {
            let p = NSBezierPath(roundedRect: handleRect(c), xRadius: 2.5, yRadius: 2.5)
            theme.blue.setFill()
            p.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            p.lineWidth = 1.5
            p.stroke()
        }
    }

    private func handleRect(_ c: Corner) -> NSRect {
        let box = imageRect
        let center: NSPoint
        switch c {
        case .tl: center = NSPoint(x: box.minX, y: box.minY)
        case .tr: center = NSPoint(x: box.maxX, y: box.minY)
        case .bl: center = NSPoint(x: box.minX, y: box.maxY)
        case .br: center = NSPoint(x: box.maxX, y: box.maxY)
        }
        return NSRect(
            x: center.x - handle / 2, y: center.y - handle / 2,
            width: handle, height: handle)
    }

    private func corner(at p: NSPoint) -> Corner? {
        Corner.allCases.first { handleRect($0).insetBy(dx: -5, dy: -5).contains(p) }
    }

    // MARK: 커서 — 핸들엔 십자, 몸통엔 손 모양 (I-beam 방지)

    override func resetCursorRects() {
        discardCursorRects()
        for c in Corner.allCases {
            addCursorRect(handleRect(c).insetBy(dx: -5, dy: -5), cursor: .crosshair)
        }
        addCursorRect(imageRect, cursor: .openHand)
    }

    // MARK: 마우스

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startWinPoint = event.locationInWindow
        startWidth = textView?.imageWidthPercent(at: paraLocation) ?? 100
        didMove = false
        if let c = corner(at: p) {
            drag = .resize(c)
        } else if imageRect.contains(p) {
            drag = .move
            NSCursor.closedHand.set()
        } else {
            drag = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tv = textView else { return }
        let dx = event.locationInWindow.x - startWinPoint.x
        let dy = event.locationInWindow.y - startWinPoint.y
        if abs(dx) > 2 || abs(dy) > 2 { didMove = true }
        switch drag {
        case .resize(let c):
            // 오른쪽 모서리는 오른쪽으로, 왼쪽 모서리는 왼쪽으로 끌면 커진다.
            let grow: CGFloat = (c == .tr || c == .br) ? dx : -dx
            tv.previewImageResize(at: paraLocation, startWidth: startWidth, deltaWidth: grow)
        case .move:
            tv.updateImageDropIndicator(toViewPoint: tv.convert(event.locationInWindow, from: nil))
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let tv = textView else { return }
        switch drag {
        case .resize:
            tv.commitImageResize(at: paraLocation)
        case .move:
            if didMove {
                tv.moveImageParagraph(
                    at: paraLocation, toViewPoint: tv.convert(event.locationInWindow, from: nil))
            } else {
                tv.imageDropIndicatorY = nil  // 클릭만 — 표시선 제거
                tv.needsDisplay = true
            }
            NSCursor.openHand.set()
        case .none:
            break
        }
        drag = .none
    }
}
