import Foundation

/// Explicit story order on one timeline; unrelated timelines have no total ordering.
public struct StoryInstant: Codable, Hashable, Sendable {
    public let timelineID: UUID
    public let tick: Int64
    public init(timelineID: UUID, tick: Int64) { self.timelineID = timelineID; self.tick = tick }
}

public enum StoryTemporalOverlap: Equatable, Sendable { case overlapping, disjoint, unknown }

public enum StoryInterval: Codable, Equatable, Sendable {
    case unknown
    case point(StoryInstant)
    case range(start: StoryInstant, end: StoryInstant)
    public var isWellFormed: Bool {
        switch self {
        case .unknown, .point: true
        case .range(let start, let end): start.timelineID == end.timelineID && start.tick <= end.tick
        }
    }
    private var bounds: (StoryInstant, StoryInstant)? {
        switch self {
        case .unknown: nil
        case .point(let value): (value, value)
        case .range(let start, let end): (start, end)
        }
    }
    public func overlap(with other: Self) -> StoryTemporalOverlap {
        guard isWellFormed, other.isWellFormed, let (a, b) = bounds, let (c, d) = other.bounds,
              a.timelineID == c.timelineID else { return .unknown }
        return a.tick <= d.tick && c.tick <= b.tick ? .overlapping : .disjoint
    }
}

public enum StoryFactOrigin: Codable, Equatable, Sendable {
    case model(providerID: String)
    case deterministic(ruleID: String)
    case writerDecision(UUID)
}

public struct CharacterState: Codable, Equatable, Sendable {
    public let characterID: UUID
    public let field: StateDelta.Field
    public let value: String
    public init(characterID: UUID, field: StateDelta.Field, value: String) {
        self.characterID = characterID; self.field = field; self.value = value
    }
}

/// Explicit completed-year age on a named calendar; StoryInstant ticks have no assumed unit.
public struct CharacterAge: Codable, Equatable, Sendable {
    public let characterID: UUID
    public let completedYears: Int64
    public let calendarYear: Int64
    public let calendarID: String
    public init(characterID: UUID, completedYears: Int64, calendarYear: Int64, calendarID: String) {
        self.characterID = characterID; self.completedYears = completedYears; self.calendarYear = calendarYear; self.calendarID = calendarID
    }
}

public struct CharacterKnowledge: Codable, Equatable, Sendable {
    /// An explicit unknown can retire a prior assertion without asserting its negation.
    public enum Stance: String, Codable, Sendable { case knows, suspects, misbelieves, hides, unknown, unaware }
    public let characterID: UUID
    public let fact: String
    public let stance: Stance
    public init(characterID: UUID, fact: String, stance: Stance) {
        self.characterID = characterID; self.fact = fact; self.stance = stance
    }
}

public struct RelationshipState: Codable, Equatable, Sendable {
    public let fromID: UUID
    public let toID: UUID
    public let value: String
    public init(fromID: UUID, toID: UUID, value: String) {
        self.fromID = fromID; self.toID = toID; self.value = value
    }
}

public struct ObjectState: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable { case condition, location, owner }
    public let objectID: UUID
    public let field: Field
    public let value: String
    public init(objectID: UUID, field: Field, value: String) {
        self.objectID = objectID; self.field = field; self.value = value
    }
}

public struct WorldRuleState: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let statement: String
    public init(ruleID: UUID, statement: String) { self.ruleID = ruleID; self.statement = statement }
}

/// Derived assertion metadata. Shape validation alone never verifies an original or a claim.
public struct StoryFact: Codable, Equatable, Sendable, Identifiable {
    public enum Content: Codable, Equatable, Sendable {
        case event(summary: String, participants: [UUID])
        case characterState(CharacterState)
        case characterAge(CharacterAge)
        case characterKnowledge(CharacterKnowledge)
        case relationship(RelationshipState)
        case objectState(ObjectState)
        case worldRule(WorldRuleState)
    }
    /// Caller-supplied derived cache key, never a persistent manuscript identity.
    public let derivedID: String
    public var id: String { derivedID }
    public let scope: StoryMemoryScope
    public var documentID: WritingDocumentID { scope.documentID }
    public let content: Content
    public let evidence: EvidenceAnchor
    public let discourseRange: Range<Int>
    public let storyInterval: StoryInterval
    public let confidence: Double?
    public let origin: StoryFactOrigin
    public init(derivedID: String, scope: StoryMemoryScope, content: Content, evidence: EvidenceAnchor,
                discourseRange: Range<Int>, storyInterval: StoryInterval = .unknown,
                confidence: Double? = nil, origin: StoryFactOrigin) {
        self.derivedID = derivedID; self.scope = scope; self.content = content; self.evidence = evidence
        self.discourseRange = discourseRange; self.storyInterval = storyInterval; self.confidence = confidence; self.origin = origin
    }
    public var isWellFormed: Bool {
        guard Self.validID(derivedID), documentID == evidence.documentID,
              discourseRange.lowerBound >= 0, discourseRange.upperBound > discourseRange.lowerBound,
              storyInterval.isWellFormed, Self.validText(evidence.quote),
              confidence.map({ $0.isFinite && (0...1).contains($0) }) != false else { return false }
        if let hint = evidence.utf16Hint {
            guard hint >= discourseRange.lowerBound, hint <= discourseRange.upperBound,
                  evidence.quote.utf16.count <= discourseRange.upperBound - hint else { return false }
        } else if evidence.quote.utf16.count > discourseRange.upperBound - discourseRange.lowerBound { return false }
        switch origin {
        case .model(let id), .deterministic(let id): if !Self.validID(id) { return false }
        case .writerDecision: break
        }
        switch content {
        case .event(let summary, let participants):
            return Self.validText(summary) && participants.count <= 64 && Set(participants).count == participants.count
        case .characterState(let value): return Self.validText(value.value)
        case .characterAge(let value):
            return value.completedYears >= 0 && !value.calendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.calendarID.utf8.count <= 128
        case .characterKnowledge(let value): return Self.validText(value.fact)
        case .relationship(let value): return Self.validText(value.value)
        case .objectState(let value): return Self.validText(value.value)
        case .worldRule(let value): return Self.validText(value.statement)
        }
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
    private static func validText(_ value: String) -> Bool {
        value.utf16.count <= 4096 && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.derivedID == rhs.derivedID && lhs.scope == rhs.scope && lhs.content == rhs.content
            && lhs.discourseRange == rhs.discourseRange && lhs.storyInterval == rhs.storyInterval
            && lhs.confidence == rhs.confidence && lhs.origin == rhs.origin
            && lhs.evidence.documentID == rhs.evidence.documentID && lhs.evidence.sceneHash == rhs.evidence.sceneHash
            && lhs.evidence.utf16Hint == rhs.evidence.utf16Hint && lhs.evidence.quote.utf16.elementsEqual(rhs.evidence.quote.utf16)
    }
}
