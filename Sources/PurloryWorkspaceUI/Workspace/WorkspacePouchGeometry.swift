import AppKit

enum WorkspacePouchEdge: String, Codable { case left, right, top, bottom }

/// The trigger and popover are presentation-only, independent of object sizing
/// and scroll extent. A narrow object may open a full-width card over its neighbor.
struct WorkspacePouchPlacement: Equatable {
    let frame: CGRect
    let trigger: CGRect
    let card: CGRect

    init?(anchor: CGRect, visible: CGRect, toolHeight: CGFloat) {
        // The fixed chrome trigger sits immediately above the scrollable canvas.
        guard visible.width > 0, visible.height > 0,
              anchor.maxX > visible.minX, anchor.minX < visible.maxX else { return nil }
        guard toolHeight > 0 else {
            frame = anchor; trigger = CGRect(origin: .zero, size: anchor.size); card = .zero
            return
        }
        let available = visible.insetBy(dx: 8, dy: 8)
        let width = min(WorkspacePouchStyle.width, max(0, available.width))
        let below = max(available.minY, anchor.maxY + 6)
        let above = min(available.maxY, anchor.minY - 6)
        let belowSpace = max(0, available.maxY - below)
        let aboveSpace = max(0, above - available.minY)
        // Keep the opening edge stable as inline tools grow or shrink.
        let opensBelow = belowSpace >= aboveSpace
        let height = min(toolHeight, opensBelow ? belowSpace : aboveSpace)
        guard width > 0, height > 0 else { return nil }
        let x = min(max(available.minX, anchor.maxX - width), available.maxX - width)
        let y = opensBelow ? below : above - height
        let popover = CGRect(x: x, y: y, width: width, height: height)
        frame = anchor.union(popover.insetBy(dx: -WorkspacePouchStyle.shadowInset, dy: -WorkspacePouchStyle.shadowInset))
        trigger = anchor.offsetBy(dx: -frame.minX, dy: -frame.minY)
        card = popover.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
}

enum WorkspacePouchGeometry {
    static func dockedFrame(window: CGRect, edge: WorkspacePouchEdge, ratio: Double) -> CGRect {
        let horizontal = edge == .top || edge == .bottom
        let size = horizontal ? CGSize(width: 236, height: 38) : CGSize(width: 38, height: 236)
        let ratio = min(0.95, max(0.05, ratio.isFinite ? ratio : 0.45))
        let availableWidth = max(40, window.width - size.width - 16)
        let availableHeight = max(40, window.height - 36 - size.height - 16)
        let x: CGFloat, y: CGFloat
        switch edge {
        case .left: x = window.minX + 8; y = window.maxY - 44 - size.height - availableHeight * ratio
        case .right: x = window.maxX - size.width - 8; y = window.maxY - 44 - size.height - availableHeight * ratio
        case .top: x = window.minX + 8 + availableWidth * ratio; y = window.maxY - 44 - size.height
        case .bottom: x = window.minX + 8 + availableWidth * ratio; y = window.minY + 8
        }
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
    static func nearestEdge(point: CGPoint, window: CGRect) -> WorkspacePouchEdge {
        let distances: [(WorkspacePouchEdge, CGFloat)] = [(.left, abs(point.x - window.minX)),
            (.right, abs(window.maxX - point.x)), (.top, abs(window.maxY - 36 - point.y)),
            (.bottom, abs(point.y - window.minY))]
        return distances.min { $0.1 < $1.1 }!.0
    }
    static func clampOrb(_ origin: CGPoint, screen: CGRect, margin: CGFloat = 12) -> CGPoint {
        CGPoint(x: min(screen.maxX - 44 - margin, max(screen.minX + margin, origin.x)),
                y: min(screen.maxY - 44 - margin, max(screen.minY + margin, origin.y)))
    }
}

struct WorkspaceSpringPoint {
    var position: CGPoint
    var velocity = CGVector.zero
    mutating func step(target: CGPoint, stiffness: CGFloat, damping: CGFloat, elapsed: TimeInterval) {
        let dt = CGFloat(min(0.030, max(0.004, elapsed)))
        velocity.dx += ((target.x - position.x) * stiffness - velocity.dx * damping) * dt
        velocity.dy += ((target.y - position.y) * stiffness - velocity.dy * damping) * dt
        position.x += velocity.dx * dt; position.y += velocity.dy * dt
    }
    func isSettled(at target: CGPoint) -> Bool {
        hypot(position.x - target.x, position.y - target.y) < 0.15 && hypot(velocity.dx, velocity.dy) < 0.8
    }
}
