import Foundation

/// Reads the verified archive, never an EntryStore or mutable legacy entries.json.
public enum ProjectWriterDataMigration {
    private static let markerKey = "writer-migration-v1"
    private static let completed = Data([1])
    private struct Archive: Decodable { let entries: [JournalEntry] }

    public static func prepare(_ project: WritingProject, store: ProjectStore) async throws -> WritingProject {
        try Task.checkCancellation()
        let current = try await store.load(id: project.id)
        guard current == project else { throw ProjectStoreError.changedDuringSave }
        for document in project.documents {
            _ = try WriterDocumentData.decode(project.userData[WriterDocumentData.key(for: document.id)], documentID: document.id)
        }
        if let marker = project.userData[markerKey] {
            guard marker == completed else { throw WriterDocumentData.Failure.invalidMigration }
            return project
        }
        guard let source = try await store.legacySource(id: project.id) else { return project }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode(Archive.self, from: source).entries
        guard Set(entries.map(\.id)).count == entries.count else { throw ProjectStoreError.invalidLegacy }
        let liveIDs = Set(project.documents.map(\.id))
        var updated = project
        for entry in entries {
            try Task.checkCancellation()
            let documentID = WritingDocumentID(rawValue: entry.id)
            let key = WriterDocumentData.key(for: documentID)
            guard liveIDs.contains(documentID), updated.userData[key] == nil else { continue }
            let writer = WriterDocumentData(documentID: documentID, genre: entry.genre,
                characters: entry.characters ?? [], rejectedCharacterNames: entry.rejectedCharacterNames ?? [],
                narrativeOverrides: entry.narrativeOverrides ?? [], recordedConversations: entry.recordedConversations ?? [])
            updated.userData[key] = try writer.encoded()
        }
        // The marker and all records commit together; explicit later deletions never reseed.
        updated.userData[markerKey] = completed
        try Task.checkCancellation()
        try await store.save(updated, replacing: project)
        return try await store.load(id: updated.id)
    }
}
