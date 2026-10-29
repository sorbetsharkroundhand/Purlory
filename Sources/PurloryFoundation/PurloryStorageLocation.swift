import Foundation

/// Path ownership only: constructing a location never creates or moves user data.
public struct PurloryStorageLocation: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Foundation maps Documents into the app container when sandboxed; development
    /// builds use Documents/Purlory. Previous-installation data stays untouched and
    /// can be copied through the verified project/legacy importer.
    public static let standard: PurloryStorageLocation = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return PurloryStorageLocation(rootDirectory: base.appendingPathComponent("Purlory", isDirectory: true))
    }()

    public var projectsDirectory: URL { rootDirectory.appendingPathComponent("Projects", isDirectory: true) }
    package var knowledgeDirectory: URL { rootDirectory.appendingPathComponent("knowledge", isDirectory: true) }
    package var metricsFileURL: URL { rootDirectory.appendingPathComponent("metrics.jsonl") }
    package var stopwordsFileURL: URL { rootDirectory.appendingPathComponent("character-stopwords.txt") }
}
