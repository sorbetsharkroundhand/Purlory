import Foundation

/// Centralized `UserDefaults` / `@AppStorage` keys shared across workspace chrome, settings, and editor interaction.
enum PurloryUserDefaultsKeys {
    static let appearance = "purlory.appearance"
    static let sidebarVisible = "purlory.sidebarVisible"
    static let sidebarSection = "purlory.sidebarSection"
    static let chromeHidden = "purlory.chromeHidden"
    static let navigatorSortMode = "purlory.navigator.sortMode"
    static let showsWritingDiagnosticsInEditor = "editor.showsWritingDiagnostics"
}
