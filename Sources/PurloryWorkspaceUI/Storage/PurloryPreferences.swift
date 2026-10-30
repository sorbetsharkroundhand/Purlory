import Foundation

/// The only legacy preference-name boundary. Never mutates the previous application's domain.
@MainActor
public enum PurloryPreferences {
    private static let migrationKey = "purlory.legacyPreferencesImported"

    /// Run before constructing settings or views. A sandbox may not expose the old domain;
    /// absence is not success, so a later explicit import remains possible.
    public static func prepareStandard() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.persistentDomain(forName: "app.mint.MINT"), !legacy.isEmpty else { return }
        importLegacy(legacy, into: defaults)
    }

    public static func importLegacy(_ legacy: [String: Any], into defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationKey), !legacy.isEmpty else { return }
        for (key, value) in legacy {
            // Activation and consent belong to the new installation. Project IDs remain
            // in the source until the verified importer copies their projects successfully.
            guard key != "completion.authorization", key != "mint.initialModelConfirmed",
                  key != "mint.recentProjects", !key.hasPrefix("mint.selectedDocument."),
                  !key.hasPrefix("mint.workspaceMode."), !key.hasPrefix("mint.spatial-workspace.") else { continue }
            let destination: String
            if key.hasPrefix("mint.") {
                destination = "purlory." + key.dropFirst(5)
            } else if key.hasPrefix("completion.") || key.hasPrefix("editor.") {
                destination = key
            } else {
                continue
            }
            if defaults.object(forKey: destination) == nil {
                defaults.set(value, forKey: destination)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }
}
