import Foundation

extension WritingStyleRepository {
    static func update(_ record: WritingStyleRecord, in session: ProjectSession, identity: ProjectRuntimeIdentity) throws {
        guard session.runtimeIdentity == identity, session.isEditorEditable,
              let snapshot = session.selectedDocumentSnapshot else { throw ProjectSessionError.staleRuntime }
        guard case let .ready(previous) = read(snapshot) else { throw WritingStyleRepositoryError.unreadableProfile }
        guard valid(record) else { throw WritingStyleRepositoryError.invalidRecord }
        guard record != previous else { return } // Preserve legacy/opaque bytes on semantic no-ops.
        var canonical = record
        canonical.profile.learnedWords = Set(record.profile.learnedWords.map(\.precomposedStringWithCanonicalMapping))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try session.updateUserData(encoder.encode(canonical), for: key, identity: identity)
    }

}
