import AppKit
import SwiftUI

/// Values transcribed from purlory.html. Keep motion timing shared across native surfaces.
enum WorkspaceHTMLStyle {
    /// Invert the CSS cubic-bezier X component, then evaluate Y.
    static func progress(_ time: Double, x1: Double = 0.25, y1: Double = 1,
                         x2: Double = 0.5, y2: Double = 1) -> CGFloat {
        let x = min(1, max(0, time))
        var low = 0.0, high = 1.0
        for _ in 0..<18 {
            let t = (low + high) / 2, u = 1 - t
            let sample = 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t
            if sample < x { low = t } else { high = t }
        }
        let t = (low + high) / 2, u = 1 - t
        return CGFloat(3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t)
    }
    static var calm: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1) }
    static func animation(_ duration: Double) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .timingCurve(0.25, 1, 0.5, 1, duration: duration)
    }
    static func animate(_ duration: Double, changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            context.timingFunction = calm
            changes()
        } completionHandler: { MainActor.assumeIsolated { completion?() } }
    }
}

/// Borderless source-sized controls retain AppKit keyboard and accessibility behavior.
class WorkspaceHTMLButton: NSButton {
    var theme = PurloryTheme.light
    var selected = false
    var chip = false
    var radius: CGFloat = 6
    private(set) var hovered = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false; refusesFirstResponder = true; wantsLayer = true
        imagePosition = .imageOnly; imageHugsTitle = true
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea); super.updateTrackingAreas()
        addTrackingArea(.init(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    func refresh() {
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        layer?.cornerRadius = radius
        let fill = selected ? theme.activeBg : (hovered ? theme.hover : (chip ? theme.chip : .clear))
        layer?.backgroundColor = fill.cgColor
        contentTintColor = selected ? theme.blue : (hovered ? theme.ink : theme.workspaceMuted)
        needsDisplay = true
    }
}

struct WorkspaceTextAction: NSViewRepresentable {
    let title: String
    var symbol: String? = nil
    let identifier: String
    let theme: PurloryTheme
    var chip = true
    let action: () -> Void
    func makeCoordinator() -> WorkspaceActionButton.Coordinator { .init(action: action) }
    func makeNSView(context: Context) -> WorkspaceHTMLButton {
        let button = WorkspaceHTMLButton(frame: .zero)
        button.target = context.coordinator; button.action = #selector(WorkspaceActionButton.Coordinator.invokeAction)
        return button
    }
    func updateNSView(_ button: WorkspaceHTMLButton, context: Context) {
        context.coordinator.action = action
        button.title = title; button.font = PurloryFonts.ui(10.5, weight: .medium)
        button.image = symbol.flatMap { WorkspaceIcons.image($0, size: 12) }
        button.theme = theme; button.chip = chip; button.refresh()
        button.setAccessibilityIdentifier(identifier); button.setAccessibilityLabel(title)
    }
}

/// Borderless transient panels can accept text input without adding a second title bar.
final class WorkspaceModalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class WorkspaceModalBackdrop {
    private var panel: NSPanel?
    func show(over parent: NSWindow, opacity: CGFloat) {
        let panel = NSPanel(contentRect: parent.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = true
        let surface = NSVisualEffectView(frame: .init(origin: .zero, size: parent.frame.size))
        surface.material = .hudWindow; surface.blendingMode = .withinWindow; surface.state = .active
        surface.wantsLayer = true; surface.layer?.backgroundColor = NSColor.black.withAlphaComponent(opacity).cgColor
        surface.layer?.cornerRadius = 13; panel.contentView = surface
        parent.addChildWindow(panel, ordered: .above); panel.orderFront(nil); self.panel = panel
    }
    func close() { panel?.parent?.removeChildWindow(panel!); panel?.orderOut(nil); panel?.close(); panel = nil }
}

struct WorkspaceAccessibilityProbe: NSViewRepresentable {
    let identifier: String
    var label: String = ""
    var value: String = ""
    var role: NSAccessibility.Role = .button
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(role)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label.isEmpty ? nil : label)
        view.setAccessibilityValue(value.isEmpty ? nil : value)
    }
    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
