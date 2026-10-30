import Foundation
import CryptoKit

public enum StoryFactResolution: Equatable, Sendable { case resolved(StoryFact), unknown }

public struct StoryKnowledgeSnapshot: Equatable, Sendable {
    public let scope: StoryMemoryScope
    public let sourceRevision: String
    public let sourceLength: Int
    private let facts: [StoryFact]
    private let slots: [Slot: [StoryFact]]
    private let characters: [UUID: [StoryFact]]
    private enum Slot: Hashable {
        case state(UUID, String), knowledge(UUID, String), relationship(UUID, UUID), object(UUID, String), rule(UUID)
        init?(_ content: StoryFact.Content) {
            switch content {
            case .event, .characterAge: return nil
            case .characterState(let value): self = .state(value.characterID, value.field.rawValue)
            case .characterKnowledge(let value): self = .knowledge(value.characterID, value.fact)
            case .relationship(let value): self = .relationship(value.fromID, value.toID)
            case .objectState(let value): self = .object(value.objectID, value.field.rawValue)
            case .worldRule(let value): self = .rule(value.ruleID)
            }
        }
    }

    /// Preparation alone reads the original. Query indexes retain no manuscript body.
    public init(scope: StoryMemoryScope, source: String, facts: [StoryFact], entities: StoryEntityResolver, decisions: [WriterDecision] = []) {
        self.scope = scope
        let original = Array(source.utf16)
        sourceLength = original.count
        sourceRevision = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let decisionsByID = Dictionary(grouping: decisions, by: \.id)
        let verified = facts.filter { fact in
            guard fact.scope == scope, fact.isWellFormed, entities.accepts(fact.content),
                  fact.discourseRange.upperBound <= original.count, let hint = fact.evidence.utf16Hint,
                  original[hint..<(hint + fact.evidence.quote.utf16.count)].elementsEqual(fact.evidence.quote.utf16) else { return false }
            if case .writerDecision(let id) = fact.origin {
                // A duplicated durable identity cannot grant unambiguous writer authority.
                guard let records = decisionsByID[id], records.count == 1, let first = records.first,
                      first.kind == .confirmed,
                      first.targetID == fact.derivedID,
                      first.evidence.contains(where: { Self.sameOriginal($0, fact.evidence) }) else { return false }
            }
            return true
        }
        self.facts = Dictionary(grouping: verified, by: \.derivedID).values.compactMap { copies in
            guard let first = copies.first, copies.allSatisfy({ $0 == first }) else { return nil }
            return first
        }.sorted {
            if $0.discourseRange.upperBound != $1.discourseRange.upperBound { return $0.discourseRange.upperBound < $1.discourseRange.upperBound }
            if $0.discourseRange.lowerBound != $1.discourseRange.lowerBound { return $0.discourseRange.lowerBound < $1.discourseRange.lowerBound }
            return $0.derivedID < $1.derivedID
        }
        var slots: [Slot: [StoryFact]] = [:], characters: [UUID: [StoryFact]] = [:]
        for fact in self.facts {
            if let slot = Slot(fact.content) { slots[slot, default: []].append(fact) }
            let ids: [UUID]
            switch fact.content {
            case .event(_, let participants): ids = participants
            case .characterState(let value): ids = [value.characterID]
            case .characterAge(let value): ids = [value.characterID]
            case .characterKnowledge(let value): ids = [value.characterID]
            case .relationship(let value): ids = Array(Set([value.fromID, value.toID]))
            case .objectState, .worldRule: ids = []
            }
            for id in ids { characters[id, default: []].append(fact) }
        }
        self.slots = slots; self.characters = characters
    }
    public func observations(before: Int) -> [StoryFact] { visible(facts, before: before) }
    public func observations(of character: UUID, before: Int) -> [StoryFact] { visible(characters[character] ?? [], before: before) }
    public func characterState(of character: UUID, field: StateDelta.Field, at: StoryInstant, before: Int) -> StoryFactResolution {
        resolve(.state(character, field.rawValue), at: at, before: before)
    }
    public func characterKnowledge(of character: UUID, fact: String, at: StoryInstant, before: Int) -> StoryFactResolution {
        resolve(.knowledge(character, fact), at: at, before: before)
    }
    public func knows(_ character: UUID, fact: String, at: StoryInstant, before: Int) -> StoryFactResolution {
        let result = characterKnowledge(of: character, fact: fact, at: at, before: before)
        guard case .resolved(let value) = result, case .characterKnowledge(let knowledge) = value.content,
              knowledge.stance == .knows else { return .unknown }
        return result
    }
    public func relationship(from: UUID, to: UUID, at: StoryInstant, before: Int) -> StoryFactResolution {
        resolve(.relationship(from, to), at: at, before: before)
    }
    public func objectState(of object: UUID, field: ObjectState.Field, at: StoryInstant, before: Int) -> StoryFactResolution {
        resolve(.object(object, field.rawValue), at: at, before: before)
    }
    public func worldRule(id: UUID, at: StoryInstant, before: Int) -> StoryFactResolution {
        resolve(.rule(id), at: at, before: before)
    }
    private func visible(_ records: [StoryFact], before: Int) -> [StoryFact] {
        guard (0...sourceLength).contains(before) else { return [] }
        return Array(records.prefix { $0.discourseRange.upperBound <= before })
    }
    private func resolve(_ slot: Slot, at: StoryInstant, before: Int) -> StoryFactResolution {
        var candidates: [(fact: StoryFact, start: Int64, end: Int64?)] = []
        for fact in visible(slots[slot] ?? [], before: before) {
            let start: StoryInstant, end: StoryInstant?
            switch fact.storyInterval {
            case .unknown: return .unknown
            case .point(let value): start = value; end = nil
            case .range(let a, let b): start = a; end = b
            }
            guard start.timelineID == at.timelineID else { return .unknown }
            if start.tick <= at.tick { candidates.append((fact, start.tick, end?.tick)) }
        }
        guard let latest = candidates.map(\.start).max() else { return .unknown }
        let competing = candidates.filter { $0.start == latest || $0.end.map { $0 >= at.tick } == true }
        guard let chosen = competing.first(where: { $0.start == latest }),
              competing.allSatisfy({ value in
                  (value.end.map { $0 >= at.tick } ?? true) && Self.authoritative(value.fact)
                      && value.fact.content == chosen.fact.content
              }) else { return .unknown }
        if case .characterKnowledge(let knowledge) = chosen.fact.content, knowledge.stance == .unknown { return .unknown }
        return .resolved(chosen.fact)
    }
    private static func authoritative(_ fact: StoryFact) -> Bool {
        if case .writerDecision = fact.origin { return true } // Verified against durable decisions during preparation.
        return fact.confidence.map { $0 >= 0.8 } ?? false
    }
    private static func sameOriginal(_ a: EvidenceAnchor, _ b: EvidenceAnchor) -> Bool {
        a.documentID == b.documentID && a.sceneHash == b.sceneHash && a.utf16Hint == b.utf16Hint
            && a.quote.utf16.elementsEqual(b.quote.utf16)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.sourceRevision == rhs.sourceRevision && lhs.sourceLength == rhs.sourceLength
            && lhs.facts == rhs.facts
    }
}
