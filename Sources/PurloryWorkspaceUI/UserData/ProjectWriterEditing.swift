import Foundation

public enum ProjectWriterEdit {
    case genre(String), character(CharacterCard), removeCharacter(UUID)
    case `override`(NarrativeOverride), removeOverride(NarrativeOverride.Kind, String)
    case rejectName(String), restoreName(String)
    case record(RecordedConversation), removeRecord(UUID)
    case decision(WriterDecision), removeDecision(UUID)
}

/// Domain mutations delegate persistence and ownership to the existing project session.
@MainActor
public enum ProjectWriterEditing {
    public static func perform(_ edit: ProjectWriterEdit, in session: ProjectSession,
                               identity: ProjectRuntimeIdentity) throws {
        guard let snapshot = session.selectedDocumentSnapshot, snapshot.identity == identity else {
            throw ProjectSessionError.staleRuntime
        }
        let id = identity.key.documentID, key = WriterDocumentData.key(for: id)
        let original = try WriterDocumentData.decode(snapshot.userData[key], documentID: id)
        var writer = original
        switch edit {
        case .genre(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            writer.genre = trimmed.isEmpty ? nil : trimmed
        case .character(var card):
            if let index = writer.characters.firstIndex(where: { $0.id == card.id }) {
                let existing = writer.characters[index]
                if card.note != existing.note { card.locked = true }
                if card != existing { card.autoRegistered = nil }
                writer.characters[index] = card
            } else { writer.characters.append(card) }
        case .removeCharacter(let id): writer.characters.removeAll { $0.id == id }
        case .override(let value):
            writer.narrativeOverrides.removeAll { $0.id == value.id }
            writer.narrativeOverrides.append(value)
        case .removeOverride(let kind, let key):
            writer.narrativeOverrides.removeAll { $0.kind == kind && $0.key == key }
        case .rejectName(let name):
            if !writer.rejectedCharacterNames.contains(name) { writer.rejectedCharacterNames.append(name) }
        case .restoreName(let name): writer.rejectedCharacterNames.removeAll { $0 == name }
        case .record(let record):
            if !writer.recordedConversations.contains(where: { $0.contentHash == record.contentHash }) {
                writer.recordedConversations.append(record)
            }
        case .removeRecord(let id): writer.recordedConversations.removeAll { $0.id == id }
        case .decision(let value):
            if let index = writer.decisions.firstIndex(where: { $0.id == value.id }) { writer.decisions[index] = value }
            else { writer.decisions.append(value) }
        case .removeDecision(let id): writer.decisions.removeAll { $0.id == id }
        }
        guard writer != original else { return }
        try session.updateUserData(writer.encoded(), for: key, identity: identity)
    }
}
