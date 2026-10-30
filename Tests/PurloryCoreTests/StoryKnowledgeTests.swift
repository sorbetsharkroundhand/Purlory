@testable import PurloryIntelligence
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class StoryKnowledgeTests: XCTestCase {
    private let documentID = WritingDocumentID()

    func testIntervalsOnlyCompareProvenTimesOnTheSameTimeline() {
        let timeline = UUID()
        func at(_ tick: Int64) -> StoryInstant { .init(timelineID: timeline, tick: tick) }
        let range = StoryInterval.range(start: at(2), end: at(5))
        XCTAssertEqual(range.overlap(with: .point(at(3))), .overlapping)
        XCTAssertEqual(range.overlap(with: .point(at(5))), .overlapping)
        XCTAssertEqual(range.overlap(with: .point(at(6))), .disjoint)
        XCTAssertEqual(StoryInterval.point(at(-4)).overlap(with: .point(at(-4))), .overlapping)
        XCTAssertEqual(range.overlap(with: .unknown), .unknown)
        XCTAssertEqual(range.overlap(with: .point(.init(timelineID: UUID(), tick: 3))), .unknown)
        XCTAssertEqual(StoryInterval.range(start: at(.min), end: at(.max)).overlap(with: .point(at(.max))), .overlapping)
    }

    func testMalformedIntervalsCannotClaimOverlapOrDisjointness() {
        let timeline = UUID(), other = UUID()
        let at = StoryInstant(timelineID: timeline, tick: 3)
        for invalid in [StoryInterval.range(start: at, end: .init(timelineID: timeline, tick: 1)),
                        .range(start: at, end: .init(timelineID: other, tick: 8))] {
            XCTAssertFalse(invalid.isWellFormed)
            XCTAssertEqual(invalid.overlap(with: .point(at)), .unknown)
        }
        XCTAssertTrue(StoryInterval.unknown.isWellFormed)
    }

    func testAllAtomicKindsRoundTripWithOriginalEvidenceAndProvenance() throws {
        let a = UUID(), b = UUID()
        let contents: [StoryFact.Content] = [
            .event(summary: "The door opened", participants: [a]),
            .characterState(.init(characterID: a, field: .location, value: "도서관")),
            .characterKnowledge(.init(characterID: a, fact: "숨겨진 문", stance: .knows)),
            .relationship(.init(fromID: a, toID: b, value: "trusts")),
            .objectState(.init(objectID: UUID(), field: .condition, value: "restored")),
            .worldRule(.init(ruleID: UUID(), statement: "Magic requires moonlight"))]
        let source = "🙂 한 원문"
        for (index, content) in contents.enumerated() {
            let origin: StoryFactOrigin = index == 0 ? .writerDecision(UUID()) : .deterministic(ruleID: "fixture-rule")
            let value = makeFact(content: content, quote: source, confidence: 1, origin: origin)
            XCTAssertTrue(value.isWellFormed)
            let decoded = try JSONDecoder().decode(StoryFact.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded, value)
            XCTAssertTrue(decoded.evidence.quote.utf16.elementsEqual(source.utf16))
            XCTAssertEqual(decoded.origin, origin); XCTAssertEqual(decoded.documentID, documentID)
        }
    }

    func testUnknownConfidenceIsRetainedAndInvalidScoresRefuse() {
        XCTAssertTrue(makeFact().isWellFormed)
        XCTAssertNil(makeFact().confidence)
        XCTAssertEqual(makeFact().storyInterval, .unknown)
        for confidence in [-0.1, 1.1, .infinity, -.infinity, .nan] {
            XCTAssertFalse(makeFact(confidence: confidence).isWellFormed)
        }
    }

    func testExplicitUnknownKnowledgeRoundTripsWithoutBecomingKnown() throws {
        let value = makeFact(content: .characterKnowledge(.init(characterID: UUID(), fact: "secret", stance: .unknown)))
        XCTAssertTrue(value.isWellFormed)
        let decoded = try JSONDecoder().decode(StoryFact.self, from: JSONEncoder().encode(value))
        guard case .characterKnowledge(let knowledge) = decoded.content else { return XCTFail("Keep the knowledge kind") }
        XCTAssertEqual(knowledge.stance, .unknown)
    }

    func testMalformedOriginalOwnershipAndRangesRefuseWithoutOverflow() {
        XCTAssertFalse(makeFact(quote: "").isWellFormed)
        XCTAssertFalse(makeFact(range: -1..<30).isWellFormed)
        XCTAssertFalse(makeFact(range: 0..<0).isWellFormed)
        XCTAssertFalse(makeFact(hint: Int.max).isWellFormed)
        XCTAssertFalse(makeFact(hint: -1).isWellFormed)
        XCTAssertFalse(makeFact(quote: "long evidence", range: 0..<2).isWellFormed)
        XCTAssertFalse(makeFact(evidenceDocument: WritingDocumentID()).isWellFormed)
        XCTAssertFalse(makeFact(derivedID: "").isWellFormed)
        XCTAssertFalse(makeFact(derivedID: "한").isWellFormed)
        XCTAssertFalse(makeFact(content: .characterState(.init(characterID: UUID(), field: .goal, value: " \n"))).isWellFormed)
        XCTAssertFalse(makeFact(origin: .model(providerID: "")).isWellFormed)
    }

    func testCanonicalEqualityDoesNotMergeDifferentOriginalEvidence() {
        let decomposed = makeFact(quote: "한🙂")
        let composed = makeFact(quote: "한🙂")
        XCTAssertEqual(decomposed.evidence.quote, composed.evidence.quote)
        XCTAssertTrue(decomposed.isWellFormed); XCTAssertTrue(composed.isWellFormed)
        XCTAssertNotEqual(decomposed, composed)
    }

    func testByteIdenticalDocumentsRetainProjectAndLegacyScope() {
        func fact(_ scope: StoryMemoryScope) -> StoryFact {
            .init(derivedID: "same-derived-id", scope: scope, content: .event(summary: "Same event", participants: []),
                  evidence: .init(documentID: documentID, quote: "Same original", utf16Hint: 0),
                  discourseRange: 0..<30, origin: .model(providerID: "fixture"))
        }
        let aScope = StoryMemoryScope.project(projectID: WritingProjectID(), documentID: documentID)
        let bScope = StoryMemoryScope.project(projectID: WritingProjectID(), documentID: documentID)
        let a = fact(aScope), b = fact(bScope), legacy = fact(.legacy(documentID: documentID))
        XCTAssertTrue(a.isWellFormed); XCTAssertTrue(b.isWellFormed)
        XCTAssertEqual(a.documentID, b.documentID); XCTAssertEqual(a.evidence, b.evidence)
        XCTAssertEqual(a.scope, aScope); XCTAssertNotEqual(a, b); XCTAssertNotEqual(a, legacy)
    }

    func testBoundedRecordsRefuseOversizeWithoutTruncatingOriginalEvidence() {
        let original = String(repeating: "🙂", count: 2048)
        let valid = makeFact(quote: original, range: 0..<4096)
        XCTAssertTrue(valid.isWellFormed)
        XCTAssertTrue(valid.evidence.quote.utf16.elementsEqual(original.utf16))
        XCTAssertFalse(makeFact(quote: original + "x", range: 0..<5000).isWellFormed)
        XCTAssertFalse(makeFact(derivedID: String(repeating: "x", count: 257)).isWellFormed)
        let participants = (0..<65).map { _ in UUID() }
        XCTAssertFalse(makeFact(content: .event(summary: "Event", participants: participants)).isWellFormed)
        XCTAssertTrue(makeFact(content: .event(summary: "Event", participants: Array(participants.prefix(64)))).isWellFormed)
        XCTAssertFalse(makeFact(content: .event(summary: "Event", participants: [participants[0], participants[0]])).isWellFormed)
        XCTAssertFalse(makeFact(content: .worldRule(.init(ruleID: UUID(), statement: "  "))).isWellFormed)
    }

    private func makeFact(content: StoryFact.Content = .event(summary: "Synthetic event", participants: []),
                          quote: String = "Original evidence", range: Range<Int> = 0..<100, hint: Int? = 0,
                          evidenceDocument: WritingDocumentID? = nil, derivedID: String = "derived-fact-1",
                          confidence: Double? = nil, origin: StoryFactOrigin = .model(providerID: "fixture")) -> StoryFact {
        .init(derivedID: derivedID, scope: .legacy(documentID: documentID), content: content,
              evidence: .init(documentID: evidenceDocument ?? documentID, quote: quote, utf16Hint: hint),
              discourseRange: range, storyInterval: .unknown, confidence: confidence, origin: origin)
    }
}
