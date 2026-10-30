@testable import PurloryIntelligence
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class StoryKnowledgeQueryTests: XCTestCase {
    private let document = WritingDocumentID(), character = UUID(), other = UUID(), object = UUID(), rule = UUID(), timeline = UUID()
    private let source = String(repeating: "evidence ", count: 20)
    private var scope: StoryMemoryScope { .legacy(documentID: document) }
    private func at(_ tick: Int64) -> StoryInstant { .init(timelineID: timeline, tick: tick) }
    private func state(_ value: String) -> StoryFact.Content { .characterState(.init(characterID: character, field: .location, value: value)) }
    private func fact(_ id: String, _ content: StoryFact.Content, tick: Int64 = 1, end: Int = 9,
                      interval: StoryInterval? = nil, confidence: Double? = 0.9,
                      origin: StoryFactOrigin = .model(providerID: "fixture"),
                      quote: String = "evidence", hint: Int? = 0, owner: StoryMemoryScope? = nil) -> StoryFact {
        .init(derivedID: id, scope: owner ?? scope, content: content,
              evidence: .init(documentID: document, quote: quote, utf16Hint: hint), discourseRange: 0..<end,
              storyInterval: interval ?? .point(at(tick)), confidence: confidence, origin: origin)
    }
    private func snapshot(_ facts: [StoryFact], source: String? = nil, decisions: [WriterDecision] = []) -> StoryKnowledgeSnapshot {
        .init(scope: scope, source: source ?? self.source, facts: facts,
              entities: .init(characters: [.init(id: character, name: "A"), .init(id: other, name: "B")],
                              objects: [.init(id: object, name: "Key")], rules: [.init(id: rule, name: "Rule")]), decisions: decisions)
    }
    private func location(_ snapshot: StoryKnowledgeSnapshot, tick: Int64 = 10, before: Int = 100) -> StoryFactResolution {
        snapshot.characterState(of: character, field: .location, at: at(tick), before: before)
    }

    func testFlashbackUsesStoryTimeButCannotLeakBeforeItsCompleteDiscourseContext() {
        let present = fact("present", state("station"), tick: 8, end: 18)
        let flashback = fact("flashback", state("home"), tick: 2, end: 90)
        let view = snapshot([flashback, present])
        XCTAssertEqual(location(view, tick: 3, before: 89), .unknown)
        XCTAssertEqual(location(view, tick: 3, before: 90), .resolved(flashback))
        XCTAssertEqual(location(view, tick: 10), .resolved(present))
        XCTAssertEqual(view.observations(before: 89), [present])
        XCTAssertEqual(view.observations(of: character, before: 90), [present, flashback])
        for cutoff in [-1, Int.max, source.utf16.count + 1] {
            XCTAssertEqual(location(view, before: cutoff), .unknown)
            XCTAssertTrue(view.observations(before: cutoff).isEmpty)
        }
    }

    func testKnowledgeAcquisitionUnknownResetAndAllNonKnowingStancesRefuse() {
        let known = fact("known", .characterKnowledge(.init(characterID: character, fact: "secret", stance: .knows)), tick: 4, end: 20)
        let reset = fact("reset", .characterKnowledge(.init(characterID: character, fact: "secret", stance: .unknown)), tick: 7, end: 80)
        let view = snapshot([known, reset])
        XCTAssertEqual(view.knows(character, fact: "secret", at: at(3), before: 100), .unknown)
        XCTAssertEqual(view.knows(character, fact: "secret", at: at(6), before: 19), .unknown)
        XCTAssertEqual(view.knows(character, fact: "secret", at: at(6), before: 20), .resolved(known))
        XCTAssertEqual(view.characterKnowledge(of: character, fact: "secret", at: at(8), before: 100), .unknown)
        for stance in [CharacterKnowledge.Stance.suspects, .hides, .misbelieves] {
            let value = fact("stance", .characterKnowledge(.init(characterID: character, fact: "secret", stance: stance)))
            XCTAssertEqual(snapshot([value]).knows(character, fact: "secret", at: at(5), before: 100), .unknown)
            XCTAssertEqual(snapshot([value]).characterKnowledge(of: character, fact: "secret", at: at(5), before: 100), .resolved(value))
        }
    }

    func testUnknownUnrelatedTimeConfidenceAndSameTimeConflictsNeverChooseAnAssertion() {
        let established = fact("old", state("home"))
        let uncertain = [fact("unknown", state("away"), interval: .unknown),
                         fact("other-time", state("away"), interval: .point(.init(timelineID: UUID(), tick: 1))),
                         fact("low", state("away"), tick: 4, confidence: 0.79),
                         fact("nil", state("away"), tick: 4, confidence: nil),
                         fact("conflict", state("away"))]
        for value in uncertain { XCTAssertEqual(location(snapshot([established, value])), .unknown, value.derivedID) }
        let future = fact("future", state("away"), tick: 11, confidence: nil)
        XCTAssertEqual(location(snapshot([established, future])), .resolved(established))
        let threshold = fact("threshold", state("away"), tick: 4, confidence: 0.8)
        XCTAssertEqual(location(snapshot([threshold])), .resolved(threshold))
    }

    func testExpiredLatestRangeDoesNotResurrectEarlierStateAndActiveRangeConflictsRefuse() {
        let old = fact("old", state("home"))
        let bounded = fact("bounded", state("away"), interval: .range(start: at(3), end: at(5)))
        XCTAssertEqual(location(snapshot([old, bounded]), tick: 4), .resolved(bounded))
        XCTAssertEqual(location(snapshot([old, bounded]), tick: 6), .unknown)
        let newer = fact("new", state("station"), tick: 7)
        XCTAssertEqual(location(snapshot([old, bounded, newer]), tick: 8), .resolved(newer))
        let active = fact("active", state("away"), interval: .range(start: at(2), end: at(20)))
        XCTAssertEqual(location(snapshot([active, newer]), tick: 8), .unknown)
        let equal = fact("equal", state("station"), tick: 7)
        XCTAssertEqual(location(snapshot([newer, equal]), tick: 8), location(snapshot([equal, newer]), tick: 8))
    }

    func testObjectRestorationDirectedRelationshipAndWorldRuleUseIndependentTypedSlots() {
        let destroyed = fact("destroyed", .objectState(.init(objectID: object, field: .condition, value: "destroyed")), tick: 2)
        let restored = fact("restored", .objectState(.init(objectID: object, field: .condition, value: "restored")), tick: 6)
        let relation = fact("relation", .relationship(.init(fromID: character, toID: other, value: "trusts")))
        let world = fact("world", .worldRule(.init(ruleID: rule, statement: "Moonlight is required")))
        let view = snapshot([restored, destroyed, relation, world])
        XCTAssertEqual(view.objectState(of: object, field: .condition, at: at(4), before: 100), .resolved(destroyed))
        XCTAssertEqual(view.objectState(of: object, field: .condition, at: at(8), before: 100), .resolved(restored))
        XCTAssertEqual(view.relationship(from: character, to: other, at: at(8), before: 100), .resolved(relation))
        XCTAssertEqual(view.relationship(from: other, to: character, at: at(8), before: 100), .unknown)
        XCTAssertEqual(view.worldRule(id: rule, at: at(8), before: 100), .resolved(world))
        XCTAssertEqual(view.observations(of: other, before: 100), [relation])
    }

    func testPreparationVerifiesRawOriginalScopeRegistrationAndDuplicateIDs() {
        let valid = fact("valid", state("home"))
        let wrongScope = fact("wrong-scope", state("away"), owner: .project(projectID: .init(), documentID: document))
        let unknown = fact("unknown-character", .characterState(.init(characterID: UUID(), field: .location, value: "away")))
        let invalid = [wrongScope, unknown, fact("no-hint", state("away"), hint: nil),
                       fact("wrong-hint", state("away"), hint: 1), fact("out-of-source", state("away"), end: 200)]
        XCTAssertEqual(snapshot([valid] + invalid).observations(before: 100), [valid])
        XCTAssertEqual(snapshot([valid, valid]).observations(before: 100), [valid])
        let duplicate = fact("valid", state("away"))
        XCTAssertTrue(snapshot([valid, duplicate]).observations(before: 100).isEmpty)
        let foreignDuplicate = fact("valid", state("away"), owner: .project(projectID: .init(), documentID: document))
        XCTAssertEqual(snapshot([valid, foreignDuplicate]).observations(before: 100), [valid])
        let nfd = "한🙂 text"
        let composed = fact("nfc", state("home"), end: nfd.utf16.count, quote: "한🙂")
        XCTAssertTrue(snapshot([composed], source: nfd).observations(before: nfd.utf16.count).isEmpty)
        let replacement = fact("half-surrogate", state("home"), end: 3, quote: "�", hint: 1)
        XCTAssertTrue(snapshot([replacement], source: "🙂x").observations(before: 3).isEmpty)
        let exact = fact("nfd", state("home"), end: nfd.utf16.count, quote: "한🙂")
        XCTAssertEqual(snapshot([exact], source: nfd).observations(before: nfd.utf16.count), [exact])
    }

    func testWriterOriginRequiresGenuineMatchingConfirmedDecisionAndExactOriginalEvidence() {
        let id = UUID()
        let value = fact("confirmed", state("home"), confidence: nil, origin: .writerDecision(id))
        let decision = WriterDecision(id: id, kind: .confirmed, targetID: value.derivedID, statement: "Confirmed", evidence: [value.evidence])
        XCTAssertEqual(location(snapshot([value], decisions: [decision])), .resolved(value))
        XCTAssertEqual(location(snapshot([value])), .unknown)
        for wrong in [WriterDecision(kind: .confirmed, targetID: value.derivedID, statement: "Wrong ID", evidence: [value.evidence]),
                      WriterDecision(id: id, kind: .dismissed, targetID: value.derivedID, statement: "Dismissed", evidence: [value.evidence]),
                      WriterDecision(id: id, kind: .confirmed, targetID: "other", statement: "Wrong target", evidence: [value.evidence]),
                      WriterDecision(id: id, kind: .confirmed, targetID: value.derivedID, statement: "Missing evidence")] {
            XCTAssertEqual(location(snapshot([value], decisions: [wrong])), .unknown)
        }
        XCTAssertNil(value.confidence)
    }

    func testConflictingDuplicateDecisionIdentityCannotPromoteCanonicalEvidence() {
        let original = "한🙂 text", id = UUID()
        let value = fact("confirmed", state("home"), end: original.utf16.count, confidence: nil,
                         origin: .writerDecision(id), quote: "한🙂")
        let decision = WriterDecision(id: id, kind: .confirmed, targetID: value.id, statement: "Confirmed", evidence: [value.evidence])
        var other = decision
        other.evidence[0].quote = "한🙂"
        XCTAssertEqual(decision, other) // Swift's semantic equality does not prove original identity.
        XCTAssertEqual(location(snapshot([value], source: original, decisions: [other]), before: original.utf16.count), .unknown)
        XCTAssertEqual(location(snapshot([value], source: original, decisions: [decision, other]), before: original.utf16.count), .unknown)
        XCTAssertEqual(location(snapshot([value], source: original, decisions: [decision, decision]), before: original.utf16.count), .unknown)
    }

    func testEveryTypedSubjectAndBothProjectScopesRequireRegistrationAndExactOwnership() {
        let unregistered = UUID()
        let invalid: [StoryFact.Content] = [
            .event(summary: "Event", participants: [character, unregistered]),
            .characterKnowledge(.init(characterID: unregistered, fact: "secret", stance: .knows)),
            .relationship(.init(fromID: character, toID: unregistered, value: "trusts")),
            .objectState(.init(objectID: unregistered, field: .condition, value: "whole")),
            .worldRule(.init(ruleID: unregistered, statement: "Magic"))]
        XCTAssertTrue(snapshot(invalid.enumerated().map { fact("invalid-\($0.offset)", $0.element) }).observations(before: 100).isEmpty)
        let a = StoryMemoryScope.project(projectID: .init(), documentID: document)
        let b = StoryMemoryScope.project(projectID: .init(), documentID: document)
        let value = fact("same-id", state("home"), owner: a)
        let view = StoryKnowledgeSnapshot(scope: b, source: source, facts: [value], entities: .init(characters: [.init(id: character, name: "A")]))
        XCTAssertTrue(view.observations(before: 100).isEmpty)
    }
}
