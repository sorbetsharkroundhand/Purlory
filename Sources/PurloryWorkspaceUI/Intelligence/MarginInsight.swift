import Foundation

/// A value-described action emitted by an intelligence provider. Living Margin renders
/// the action and delegates execution to its owner; it never performs analysis itself.
public struct MarginAction: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case jumpToEvidence
        case dismiss
        case markIntentional
        case showAlternatives
        case custom
    }

    public var id: String
    public var kind: Kind
    public var title: String

    public init(id: String, kind: Kind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

/// Shared presentation contract for General Writing and Fiction intelligence.
public struct MarginInsight: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case continuity
        case openThread
        case sceneContext
        case suggestion
        case writingQuality
        case generalReview
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var message: String
    public var evidence: [EvidenceAnchor]
    public var confidence: Double?
    public var actions: [MarginAction]

    public init(
        id: String,
        kind: Kind,
        title: String,
        message: String,
        evidence: [EvidenceAnchor] = [],
        confidence: Double? = nil,
        actions: [MarginAction] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.evidence = evidence
        self.confidence = confidence
        self.actions = actions
    }
}
