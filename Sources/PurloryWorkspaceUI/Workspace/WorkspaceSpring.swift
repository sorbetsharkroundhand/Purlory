import AppKit
import SwiftUI

enum WorkspaceMotion {
    static let spatialResponse = 0.32
    static let navigator = Animation.spring(response: spatialResponse, dampingFraction: 1)
}

/// Analytic critical damping preserves velocity when a target changes and is
/// independent of display cadence, including a delayed foreground frame.
struct WorkspaceSpringValue {
    var value: CGFloat
    var velocity: CGFloat = 0

    mutating func advance(to target: CGFloat, elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        let omega = CGFloat(2 * Double.pi / WorkspaceMotion.spatialResponse)
        let dt = CGFloat(elapsed), offset = value - target
        let coefficient = velocity + omega * offset
        let decay = exp(-omega * dt)
        value = target + (offset + coefficient * dt) * decay
        velocity = (velocity - omega * coefficient * dt) * decay
    }

    func isSettled(at target: CGFloat) -> Bool {
        abs(value - target) < 0.15 && abs(velocity) < 0.8
    }
}

struct WorkspaceSpringRect {
    private var x: WorkspaceSpringValue
    private var y: WorkspaceSpringValue
    private var width: WorkspaceSpringValue
    private var height: WorkspaceSpringValue

    init(frame: CGRect) {
        x = .init(value: frame.minX); y = .init(value: frame.minY)
        width = .init(value: frame.width); height = .init(value: frame.height)
    }

    /// Matching a native presentation frame retains the four component velocities.
    var frame: CGRect {
        get { CGRect(x: x.value, y: y.value, width: width.value, height: height.value) }
        set {
            x.value = newValue.minX; y.value = newValue.minY
            width.value = newValue.width; height.value = newValue.height
        }
    }

    mutating func advance(to target: CGRect, elapsed: TimeInterval) {
        x.advance(to: target.minX, elapsed: elapsed); y.advance(to: target.minY, elapsed: elapsed)
        width.advance(to: target.width, elapsed: elapsed); height.advance(to: target.height, elapsed: elapsed)
    }

    func isSettled(at target: CGRect) -> Bool {
        x.isSettled(at: target.minX) && y.isSettled(at: target.minY)
            && width.isSettled(at: target.width) && height.isSettled(at: target.height)
    }
}
