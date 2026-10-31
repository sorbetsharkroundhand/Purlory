import Foundation

public protocol KnowledgeSidecarPersisting: Sendable {
    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar
    func save(
        _ sidecar: KnowledgeSidecar,
        pruningTo liveHashes: Set<String>?,
        scope: StoryMemoryScope
    ) async throws
    func replaceWithFresh(
        scope: StoryMemoryScope,
        generation: Int
    ) async throws -> KnowledgeSidecar
    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async
}

/// The only persistence selector for derived story memory.
public actor KnowledgeSidecarRepository: KnowledgeSidecarPersisting {
    public enum Error: Swift.Error, Equatable {
        case scopeMismatch
        case projectStoreUnavailable
    }

    private let projectStore: ProjectStore?
    private let legacyDirectory: URL

    public init(projectStore: ProjectStore? = nil, legacyDirectory: URL? = nil) {
        self.projectStore = projectStore
        self.legacyDirectory = legacyDirectory ?? KnowledgeSidecar.directory()
    }

    public func load(scope: StoryMemoryScope) async -> KnowledgeSidecar {
        do {
            return try await withDatabase(scope: scope) { database, original in
                if let stored = try database.loadSidecar(scope: scope) { return stored }
                let sidecar = (try? Data(contentsOf: original)).map { KnowledgeSidecar.decoded($0, for: scope) }
                    ?? KnowledgeSidecar(scope: scope)
                try database.saveSidecar(sidecar, verifying: true)
                return sidecar
            }
        } catch { return KnowledgeSidecar(scope: scope) }
    }

    public func save(
        _ sidecar: KnowledgeSidecar,
        pruningTo liveHashes: Set<String>? = nil,
        scope: StoryMemoryScope
    ) async throws {
        try Task.checkCancellation()
        guard sidecar.scope == scope else { throw Error.scopeMismatch }
        try await withDatabase(scope: scope) { database, _ in
            try database.saveSidecar(sidecar, pruningTo: liveHashes)
        }
    }

    public func replaceWithFresh(
        scope: StoryMemoryScope,
        generation: Int
    ) async throws -> KnowledgeSidecar {
        try Task.checkCancellation()
        var sidecar = KnowledgeSidecar(scope: scope)
        sidecar.generation = generation
        try await save(sidecar, scope: scope)
        return sidecar
    }

    public func remove(scope: StoryMemoryScope) async throws {
        try await withDatabase(scope: scope) { database, original in
            // An explicit cache removal also retires its old derived JSON, so it
            // cannot silently reappear as a migration input on the next load.
            if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.removeItem(at: original) }
            try database.removeSidecar(scope: scope)
        }
    }

    public func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {
        let probe = StoryMemoryScope.legacy(documentID: WritingDocumentID())
        try? await withDatabase(scope: probe) { database, _ in
            var retired: [StoryMemoryScope] = []
            try database.query("SELECT scope FROM sidecars") { statement in
                let key = IntelligenceDatabase.text(statement, 0)
                guard key.hasPrefix("legacy/"), let uuid = UUID(uuidString: String(key.dropFirst(7))) else { return }
                let id = WritingDocumentID(rawValue: uuid)
                if !documentIDs.contains(id) { retired.append(.legacy(documentID: id)) }
            }
            for scope in retired { try database.removeSidecar(scope: scope) }
        }
        guard (try? ProjectPaths.rejectSymlink(legacyDirectory)) != nil else { return }
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: legacyDirectory, includingPropertiesForKeys: nil)
        else { return }
        let live = Set(documentIDs.map { $0.rawValue })
        for file in files where file.pathExtension == "json" {
            let stem = file.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: stem), !live.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func withDatabase<Result: Sendable>(scope: StoryMemoryScope,
        operation: @Sendable (IntelligenceDatabase, URL) throws -> Result
    ) async throws -> Result {
        let originalName: String
        switch scope {
        case .project(let projectID, let documentID):
            guard let projectStore else { throw Error.projectStoreUnavailable }
            originalName = "\(documentID.rawValue.uuidString).knowledge.json"
            return try await projectStore.withIntelligenceFile(projectID: projectID, documentID: documentID,
                name: IntelligenceDatabase.fileName, companions: IntelligenceDatabase.companions + [originalName]) { url in
                let original = try ProjectPaths.checked(originalName, under: url.deletingLastPathComponent())
                return try IntelligenceDatabase.withConnection(at: url) { try operation($0, original) }
            }
        case .legacy(let documentID):
            try ProjectPaths.rejectSymlink(legacyDirectory)
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            originalName = "\(documentID.rawValue.uuidString).json"
            let original = try ProjectPaths.checked(originalName, under: legacyDirectory)
            let url = try ProjectPaths.checked(IntelligenceDatabase.fileName, under: legacyDirectory)
            return try IntelligenceDatabase.withConnection(at: url) { try operation($0, original) }
        }
    }
}
