import Foundation

public struct WritingDocument: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case manuscript
        case note
        case reference
    }

    public var id: WritingDocumentID
    public var title: String
    public var source: DocumentSource
    public var body: String {
        get { source.string }
        set { source = DocumentSource(newValue) }
    }
    public var kind: Kind

    public init(id: WritingDocumentID, title: String, body: String, kind: Kind) {
        self.id = id
        self.title = title
        self.source = DocumentSource(body)
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, title, body, kind }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(WritingDocumentID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        source = DocumentSource(try values.decode(String.self, forKey: .body))
        kind = try values.decode(Kind.self, forKey: .kind)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(body, forKey: .body)
        try values.encode(kind, forKey: .kind)
    }
}
