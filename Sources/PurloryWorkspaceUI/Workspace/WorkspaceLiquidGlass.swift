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
        private let tint = NSView()
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true
            setAccessibilityIdentifier("purlory.workspace.liquid-glass"); setAccessibilityElement(false)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = 18
                glass.contentView = tint; effect = glass; addSubview(glass)
            } else {
                let material = NSVisualEffectView(); material.material = .underWindowBackground
                material.blendingMode = .behindWindow; material.state = .active
                material.addSubview(tint); effect = material; addSubview(material)
            }
            tint.wantsLayer = true
        }
        required init?(coder: NSCoder) { nil }
        func configure(theme: PurloryTheme, opaque: Bool) {
            let dark = (theme.editorSurface.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5
            effect?.isHidden = opaque
            layer?.backgroundColor = opaque ? theme.workspaceSurface.cgColor : NSColor.clear.cgColor
            let gradient = CAGradientLayer()
            gradient.colors = (dark
                ? [NSColor(hex: 0x181816, alpha: 0.84), NSColor(hex: 0x111110, alpha: 0.80), NSColor(hex: 0x141716, alpha: 0.82)]
                : [NSColor(hex: 0xFCFAF5, alpha: 0.82), NSColor(hex: 0xF2EEE5, alpha: 0.76), NSColor(hex: 0xFAF8F2, alpha: 0.80)]).map(\.cgColor)
            gradient.locations = [0, 0.52, 1]; gradient.startPoint = .init(x: 0, y: 1); gradient.endPoint = .init(x: 1, y: 0)
            tint.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }; tint.layer?.addSublayer(gradient)
            tint.layer?.borderWidth = 1; tint.layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.045 : 0.35).cgColor
            tint.layer?.cornerRadius = 18; needsLayout = true
        }
        override func layout() {
            super.layout(); effect?.frame = bounds; tint.frame = bounds
            tint.layer?.sublayers?.forEach { $0.frame = bounds }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); window?.isOpaque = false; window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
