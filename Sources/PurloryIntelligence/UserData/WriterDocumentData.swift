import Foundation

/// Domain codec for existing author fields; generic project storage sees only bytes.
public struct WriterDocumentData: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let documentID: WritingDocumentID
    public var genre: String?
    public var characters: [CharacterCard]
    public var rejectedCharacterNames: [String]
    public var narrativeOverrides: [NarrativeOverride]
    public var recordedConversations: [RecordedConversation]
    public var decisions: [WriterDecision]

    public init(documentID: WritingDocumentID, genre: String? = nil, characters: [CharacterCard] = [],
                rejectedCharacterNames: [String] = [], narrativeOverrides: [NarrativeOverride] = [],
                recordedConversations: [RecordedConversation] = [], decisions: [WriterDecision] = []) {
        self.documentID = documentID; self.genre = genre; self.characters = characters
        self.rejectedCharacterNames = rejectedCharacterNames; self.narrativeOverrides = narrativeOverrides
        self.recordedConversations = recordedConversations; self.decisions = decisions
    }

    public static func key(for documentID: WritingDocumentID) -> String {
        "writer-\(documentID.rawValue.uuidString.lowercased())"
    }

    public static func decode(_ data: Data?, documentID: WritingDocumentID) throws -> Self {
        guard let data else { return Self(documentID: documentID) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.documentID == documentID else { throw Failure.documentMismatch }
        try value.validate()
        return value
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private func validate() throws {
        guard schemaVersion == 1 else { throw Failure.unsupportedSchema }
        guard Set(characters.map(\.id)).count == characters.count,
              Set(recordedConversations.map(\.id)).count == recordedConversations.count,
              Set(decisions.map(\.id)).count == decisions.count else { throw Failure.duplicateRecords }
    }

    public enum Failure: Error, LocalizedError {
        case unsupportedSchema, documentMismatch, duplicateRecords, invalidMigration
        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema: "지원하지 않는 작가 설정 저장 버전입니다."
            case .documentMismatch: "작가 설정의 문서 정보가 일치하지 않습니다."
            case .duplicateRecords: "작가 설정에 중복된 항목이 있습니다."
            case .invalidMigration: "작가 설정의 이관 기록을 확인할 수 없습니다."
            }
        }
    }
}
