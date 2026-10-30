import AppKit
import QuartzCore

/// Follows the hosting view's display, including ProMotion and screen changes.
/// Owners capture themselves weakly and stop the clock as soon as motion settles.
@MainActor final class WorkspaceDisplayClock: NSObject {
    private var link: CADisplayLink?
    private let tick: () -> Bool

    init(view: NSView, tick: @escaping () -> Bool) {
        self.tick = tick
        super.init()
        let link = view.displayLink(target: self, selector: #selector(update(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func update(_ sender: CADisplayLink) {
        if !tick() { invalidate() }
    }

    func invalidate() { link?.invalidate(); link = nil }
}
