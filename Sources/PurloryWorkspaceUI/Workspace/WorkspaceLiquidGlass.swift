import AppKit
import SwiftUI

/// One glass surface spans the outer window and tile gaps; manuscripts stay opaque.
struct WorkspaceLiquidGlass: NSViewRepresentable {
    let theme: PurloryTheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) { view.configure(theme: theme, opaque: reduceTransparency) }
    final class Surface: NSView {
        private var effect: NSView?
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true
            setAccessibilityIdentifier("purlory.workspace.liquid-glass"); setAccessibilityElement(false)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = 18
                effect = glass; addSubview(glass)
            } else {
                let material = NSVisualEffectView(); material.material = .underWindowBackground
                material.blendingMode = .behindWindow; material.state = .active
                material.wantsLayer = true
                effect = material; addSubview(material)
            }
        }
        required init?(coder: NSCoder) { nil }
        func configure(theme: PurloryTheme, opaque: Bool) {
            let dark = (theme.editorSurface.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5
            effect?.isHidden = opaque
            layer?.backgroundColor = opaque ? theme.workspaceSurface.cgColor : NSColor.clear.cgColor
            let tintColor = theme.workspaceSurface.withAlphaComponent(dark ? 0.82 : 0.78)
            if #available(macOS 26.0, *), let glass = effect as? NSGlassEffectView {
                glass.style = .regular
                glass.tintColor = tintColor
            } else if let material = effect as? NSVisualEffectView {
                material.layer?.backgroundColor = tintColor.cgColor
            }
            needsLayout = true
        }
        override func layout() {
            super.layout(); effect?.frame = bounds
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); window?.isOpaque = false; window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
