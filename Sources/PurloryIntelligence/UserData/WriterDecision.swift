import Foundation

/// Explicit writer actions are durable even when their original evidence becomes stale.
public struct WriterDecision: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case intentional, dismissed, confirmed }
    public var id: UUID
    public var kind: Kind
    public var targetID: String
    public var statement: String
    public var evidence: [EvidenceAnchor]
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, targetID: String, statement: String,
                evidence: [EvidenceAnchor] = [], createdAt: Date = .now) {
        self.id = id; self.kind = kind; self.targetID = targetID; self.statement = statement
        self.evidence = evidence; self.createdAt = createdAt
    }
}
