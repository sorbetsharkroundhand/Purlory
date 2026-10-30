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
        let data: Data?
        switch scope {
        case .project(let projectID, let documentID):
            data = try? await projectStore?.readIntelligence(
                projectID: projectID, documentID: documentID)
        case .legacy(let documentID):
            data = try? Data(contentsOf: legacyURL(documentID))
        }
        guard let data else { return KnowledgeSidecar(scope: scope) }
        return KnowledgeSidecar.decoded(data, for: scope)
    }

    public func save(
        _ sidecar: KnowledgeSidecar,
        pruningTo liveHashes: Set<String>? = nil,
        scope: StoryMemoryScope
    ) async throws {
        try Task.checkCancellation()
        guard sidecar.scope == scope else { throw Error.scopeMismatch }
        let data = try sidecar.encoded(pruningTo: liveHashes)
        switch scope {
        case .project(let projectID, let documentID):
            guard let projectStore else { throw Error.projectStoreUnavailable }
            try Task.checkCancellation()
            try await projectStore.writeIntelligence(
                data, projectID: projectID, documentID: documentID)
        case .legacy(let documentID):
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: legacyDirectory, withIntermediateDirectories: true)
            try data.write(to: legacyURL(documentID), options: .atomic)
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
        switch scope {
        case .project(let projectID, let documentID):
            guard let projectStore else { throw Error.projectStoreUnavailable }
            try await projectStore.removeIntelligence(
                projectID: projectID, documentID: documentID)
        case .legacy(let documentID):
            let url = legacyURL(documentID)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    public func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {
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

    private func legacyURL(_ documentID: WritingDocumentID) -> URL {
        legacyDirectory.appendingPathComponent("\(documentID.rawValue.uuidString).json")
    }
}
