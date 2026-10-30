import AppKit
import SwiftUI

/// The reference's Lucide vectors, rendered by AppKit without a web runtime.
@MainActor enum WorkspaceIcons {
    private static var cache: [String: NSImage] = [:]
    private static let names = [
        "folder": "folder", "person.2": "users", "person.2.fill": "users",
        "arrow.triangle.branch": "git-branch", "point.topleft.down.curvedto.point.bottomright.up": "git-branch",
        "sparkles": "sparkles", "magnifyingglass": "search", "circle.lefthalf.filled": "sun-moon",
        "rectangle.split.3x1": "columns-3", "plus": "plus", "xmark": "x",
        "doc.text": "file-text", "doc.text.fill": "file-text", "align.vertical.center": "text-align-center",
        "eye": "eye", "text.quote": "quote", "wand.and.stars": "wand-sparkles",
        "arrow.up.forward.square": "bookmark-plus", "chevron.up": "chevron-up", "chevron.down": "chevron-down",
        "grip-vertical": "grip-vertical", "file-symlink": "file-symlink", "person": "user",
    ]
    static func image(_ symbol: String, size: CGFloat = 14) -> NSImage? {
        guard let name = names[symbol] else { return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let original: NSImage?
        if let cached = cache[name] { original = cached }
        else {
            let bundle: Bundle?
            if Bundle.main.bundleURL.pathExtension == "app" {
                bundle = Bundle.main.url(forResource: "Purlory_PurloryWorkspaceUI", withExtension: "bundle").flatMap(Bundle.init(url:))
            } else { bundle = .module }
            original = bundle?.url(forResource: "purlory-icon-\(name)", withExtension: "svg").flatMap { NSImage(contentsOf: $0) }
            if let original { original.isTemplate = true; cache[name] = original }
        }
        let result = original?.copy() as? NSImage
        result?.size = .init(width: size, height: size)
        return result
    }
}

struct WorkspaceIcon: View {
    let name: String
    var size: CGFloat = 14
    var body: some View {
        if let image = WorkspaceIcons.image(name, size: size) {
            Image(nsImage: image).resizable().frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct WorkspacePaperGrain: NSViewRepresentable {
    func makeNSView(context: Context) -> Grain { Grain() }
    func updateNSView(_ view: Grain, context: Context) {}
    final class Grain: NSView {
        // The browser's filtered SVG is not a reliable AppKit texture source.
        // Cache a native tile and repeat it in view coordinates, never stretch it
        // through NSImage's vector/backing-scale conversion over the whole window.
        private static let tile: CGImage? = {
            let side = 400
            var pixels = [UInt8](repeating: 255, count: side * side * 4)
            var seed: UInt32 = 0x4D494E54
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let gray = UInt8(truncatingIfNeeded: seed >> 24)
                pixels[offset] = gray; pixels[offset + 1] = gray; pixels[offset + 2] = gray
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .duringViewResize
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let damage = dirtyRect.intersection(bounds)
            guard !damage.isEmpty, !damage.isNull else { return }
            context.saveGState()
            defer { context.restoreGState() }
            context.clip(to: damage)
            // This view owns a transparent backing layer. Repaint damage instead
            // of accumulating translucent tint when only part of it is invalidated.
            context.clear(damage)
            guard let tile = Self.tile else { return }
            context.setAlpha(0.022)
            context.setBlendMode(.normal)
            context.interpolationQuality = .none
            context.draw(tile, in: CGRect(x: 0, y: 0, width: 200, height: 200), byTiling: true)
        }
    }
}
