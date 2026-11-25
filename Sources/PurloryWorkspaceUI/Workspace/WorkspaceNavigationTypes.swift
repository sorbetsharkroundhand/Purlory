import CoreGraphics
import Foundation

/// Workspace tool section identifiers persisted via `@AppStorage("purlory.sidebarSection")`.
/// Raw value `"timeline"` is preserved for compatibility with existing saved preferences.
enum SidebarSection: String {
    case files
    case bible
    case narrative = "timeline"
    case context
    case margin
}

/// Shared navigator drag-and-drop geometry and spring-loading timing constants.
enum SidebarDnD {
    static let entryRowHeight: CGFloat = 38
    static let folderRowHeight: CGFloat = 34
    /// Top/bottom fraction of a row treated as "insert between" rather than "drop inside".
    static let edgeZoneFraction: CGFloat = 0.25
    /// Finder-convention hover duration before spring-loading a collapsed folder.
    static let springLoadDelay: Duration = .milliseconds(600)
}
