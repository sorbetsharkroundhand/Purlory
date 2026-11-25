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
