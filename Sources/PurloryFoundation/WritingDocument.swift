import Foundation

public struct WritingDocument: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case manuscript
        case note
        case reference
    }

    public var id: WritingDocumentID
    public var title: String
    public var body: String
    public var kind: Kind

    public init(id: WritingDocumentID, title: String, body: String, kind: Kind) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
    }
}
