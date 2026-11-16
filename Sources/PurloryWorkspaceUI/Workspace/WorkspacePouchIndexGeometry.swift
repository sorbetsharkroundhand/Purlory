import AppKit

/// Screen placement and the exposed slice of a surface tucked behind the window.
struct WorkspacePouchIndexGeometry {
    static let travel: CGFloat = 64
    private let seamOverlap: CGFloat = 1.5
    let frame: CGRect
    let surfaceWidth: CGFloat
    let height: CGFloat
    let slide: CGFloat
    let tail: CGFloat
    let opensInward: Bool
    let attachmentInset: CGFloat
    let materialFrame: CGRect
    var exposedWidth: CGFloat { frame.width - attachmentInset }
    var controlsMidX: CGFloat { attachmentInset + exposedWidth / 2 }

    init(window: CGRect, screen: CGRect, progress: CGFloat, hover: CGFloat) {
        let progress = min(1, max(0, progress))
        slide = min(1, max(0, hover)) * 6 * (1 - progress)
        surfaceWidth = 54 + Self.travel * progress
        let availableHeight = max(94, min(window.height, window.maxY - screen.minY))
        height = 94 + (min(528, availableHeight) - 94) * progress
        tail = min(120, height * 0.54)
        opensInward = window.maxX + 90 > screen.maxX
        attachmentInset = opensInward ? 0 : WorkspaceLiquidGlass.cornerRadius
        let width = surfaceWidth - 34 + slide + attachmentInset
        let x = opensInward ? min(window.maxX, screen.maxX) - width : window.maxX - attachmentInset
        frame = CGRect(x: x, y: window.maxY - height,
                       width: width, height: height)
        // Glass adapts its optics to its size. Continue a window-sized surface
        // through the tab mask instead of producing a separate small glass pill.
        materialFrame = opensInward ? CGRect(origin: .zero, size: frame.size)
            : CGRect(x: attachmentInset - window.width, y: 0,
                     width: window.width + width - attachmentInset, height: window.height)
    }

    var path: NSBezierPath {
        let path = outline(mirrored: false)
        if opensInward {
            path.line(to: CGPoint(x: -34 + slide, y: height)); path.close()
            mirror(path)
        } else {
            // Fill only the rounded corner's cutout; keep the glass over the
            // parent window out of this panel, including its internal seam.
            let join = attachmentInset - seamOverlap
            path.line(to: CGPoint(x: join, y: attachmentInset))
            path.curve(to: CGPoint(x: -seamOverlap, y: 0),
                       controlPoint1: CGPoint(x: join, y: attachmentInset * 0.448),
                       controlPoint2: CGPoint(x: attachmentInset * 0.552 - seamOverlap, y: 0))
            path.close()
        }
        return path
    }

    var outerEdge: NSBezierPath { outline(mirrored: opensInward) }

    private func outline(mirrored: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let x: CGFloat = attachmentInset - 34 + slide, w = surfaceWidth, h = height
        let r = min(22, w * 0.32, h * 0.24)
        path.move(to: CGPoint(x: opensInward ? x : 0, y: 0))
        path.line(to: CGPoint(x: x + w - r, y: 0))
        path.curve(to: CGPoint(x: x + w, y: r),
                   controlPoint1: CGPoint(x: x + w - r * 0.448, y: 0),
                   controlPoint2: CGPoint(x: x + w, y: r * 0.448))
        path.line(to: CGPoint(x: x + w, y: h - tail))
        // The final vertical tangent disappears under the window edge.
        path.curve(to: CGPoint(x: attachmentInset - seamOverlap, y: h),
                   controlPoint1: CGPoint(x: x + w, y: h - tail * 0.55),
                   controlPoint2: CGPoint(x: attachmentInset - seamOverlap, y: h - tail * 0.45))
        if mirrored { mirror(path) }
        return path
    }

    private func mirror(_ path: NSBezierPath) {
        path.transform(using: AffineTransform(m11: -1, m12: 0, m21: 0, m22: 1, tX: frame.width, tY: 0))
    }
}
