import Foundation

/// Cross-layer manuscript evidence. The quote remains the authority; offsets and scene
/// hashes are hints that consumers may use to narrow lookup, never proof by themselves.
public struct EvidenceAnchor: Codable, Equatable, Hashable, Sendable {
    public var documentID: WritingDocumentID
    public var sceneHash: String?
    public var quote: String
    public var utf16Hint: Int?

    public init(
        documentID: WritingDocumentID,
        sceneHash: String? = nil,
        quote: String,
        utf16Hint: Int? = nil
    ) {
        self.documentID = documentID
        self.sceneHash = sceneHash
        self.quote = quote
        self.utf16Hint = utf16Hint
    }

    /// Returns an exact search query only when the original evidence can still be
    /// re-anchored. A stale UTF-16 offset must never jump to unrelated manuscript text.
    public func resolvedQuery(in body: String) -> String? {
        SourceAnchor.resilientQuery(for: quote, in: body)
    }
}
