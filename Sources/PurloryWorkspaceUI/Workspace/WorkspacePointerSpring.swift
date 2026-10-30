import AppKit

/// A settled pointer follower: no free-running display loop after the drag ends.
@MainActor final class WorkspacePointerSpring {
    private weak var panel: NSPanel?
    private var spring: WorkspaceSpringPoint?
    private var target = CGPoint.zero
    private var timer: WorkspaceDisplayClock?
    private var lastStep = 0.0
    func move(_ panel: NSPanel, to target: CGPoint, reducedMotion: Bool) {
        self.panel = panel; self.target = target
        guard !reducedMotion, let existing = spring else {
            spring = WorkspaceSpringPoint(position: target); panel.setFrameOrigin(target); return
        }
        spring = existing
        guard timer == nil else { return }
        lastStep = ProcessInfo.processInfo.systemUptime
        guard let view = panel.contentView else { return }
        timer = WorkspaceDisplayClock(view: view) { [weak self] in
            guard let self else { return false }
            self.step()
            return self.timer != nil
        }
    }
    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        spring?.step(target: target, stiffness: 720, damping: 54, elapsed: now - lastStep); lastStep = now
        guard let spring, let panel else { stop(); return }
        panel.setFrameOrigin(spring.position)
        if spring.isSettled(at: target) { panel.setFrameOrigin(target); timer?.invalidate(); timer = nil }
    }
    func stop() { timer?.invalidate(); timer = nil; panel = nil; spring = nil }
}
