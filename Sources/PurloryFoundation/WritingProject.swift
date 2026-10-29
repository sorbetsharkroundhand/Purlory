import Foundation

public struct WritingProject: Codable, Equatable, Sendable, Identifiable {
    public var id: WritingProjectID
    public var title: String
    public var mode: WritingMode
    public var documents: [WritingDocument]
    public var trashedDocumentIDs: Set<WritingDocumentID>
    /// Opaque writer-owned records; their domain-specific codecs live outside project storage.
    public var userData: [String: Data]

    public init(
        id: WritingProjectID,
        title: String,
        mode: WritingMode,
        documents: [WritingDocument],
        trashedDocumentIDs: Set<WritingDocumentID> = [],
        userData: [String: Data] = [:]
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.documents = documents
        self.trashedDocumentIDs = trashedDocumentIDs
        self.userData = userData
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case mode
        case documents
        case trashedDocumentIDs
        case userData
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WritingProjectID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        mode = try container.decode(WritingMode.self, forKey: .mode)
        documents = try container.decode([WritingDocument].self, forKey: .documents)
        trashedDocumentIDs = try container.decodeIfPresent(
            Set<WritingDocumentID>.self, forKey: .trashedDocumentIDs) ?? []
        userData = try container.decodeIfPresent([String: Data].self, forKey: .userData) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(mode, forKey: .mode)
        try container.encode(documents, forKey: .documents)
        try container.encode(trashedDocumentIDs, forKey: .trashedDocumentIDs)
        try container.encode(userData, forKey: .userData)
    }
}
