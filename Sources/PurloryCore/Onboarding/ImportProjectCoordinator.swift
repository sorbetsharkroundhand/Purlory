import Foundation

/// Prepare copies before handing the verified project to the sole mutable session.
///
/// SwiftUI must not duplicate migration logic. The source file is read-only; ProjectStore
/// creates and verifies a separate WritingProject and activates it only after preservation
/// checks succeed.
@MainActor
public final class ImportProjectCoordinator {
    private let store: ProjectStore
    private let session: ProjectSession
    private let cancellationCheckpoint: () async throws -> Void

    public init(
        store: ProjectStore,
        session: ProjectSession,
        cancellationCheckpoint: @escaping () async throws -> Void = {
            try Task.checkCancellation()
        }
    ) {
        self.store = store
        self.session = session
        self.cancellationCheckpoint = cancellationCheckpoint
    }

    @discardableResult
    public func importProject(from sourceDirectory: URL) async throws -> WritingProjectID {
        var imported: WritingProjectID?
        try await session.activateProject(preparing: {
            let id = try await self.store.prepareProjectImport(from: sourceDirectory)
            try await self.cancellationCheckpoint()
            imported = id
            return id
        })
        guard let imported else { throw ProjectStoreError.invalidManifest }
        return imported
    }

    @discardableResult
    public func importFolder(from directory: URL, legacyMode: WritingMode, legacyFileName: String? = nil) async throws -> WritingProjectID {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        try ProjectPaths.rejectSymlink(directory)
        if legacyFileName == nil, Self.containsProjectManifest(in: directory) {
            return try await importProject(from: directory)
        }
        let selectedSource = try legacyFileName.map { try ProjectPaths.checked($0, under: directory) }
        guard let source = try selectedSource ?? LegacyProjectMigrator.source(in: directory) else { throw LegacyStartupError.noLegacyLibrary }
        return try await importLegacy(from: source,
            mode: legacyMode, title: "Imported Project").projectID
    }

    static func containsProjectManifest(in directory: URL) -> Bool {
        // lstat-style attributes also recognize dangling links; never fall back past a bad manifest.
        (try? FileManager.default.attributesOfItem(atPath:
            directory.appendingPathComponent("project.json").path)) != nil
    }

    @discardableResult
    public func importLegacy(
        from sourceURL: URL,
        mode: WritingMode,
        title: String
    ) async throws -> LegacyMigrationResult {
        var prepared: LegacyMigrationResult?
        try await session.activateProject(preparing: {
            let result = try await self.store.prepareLegacyMigration(from: sourceURL, mode: mode, title: title)
            try await self.cancellationCheckpoint()
            prepared = result
            return result.projectID
        })
        guard let result = prepared else { throw ProjectStoreError.invalidLegacy }
        if !result.reusedExistingProject, let selection = result.selectedDocumentID {
            session.selectDocument(selection)
        }
        return result
    }
}
