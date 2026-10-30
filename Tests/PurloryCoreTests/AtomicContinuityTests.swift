@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class AtomicContinuityTests: XCTestCase {
    private let actor = CharacterCard(name: "민준"), other = CharacterCard(name: "서연")
    private let object = StoryNamedEntity(id: UUID(), name: "열쇠")
    private let timeline = UUID()
    private struct Observation {
        var content: StoryFact.Content
        var time: StoryInterval
        var confidence: Double? = 0.9
        var quote: String = "원문"
    }
    private func at(_ tick: Int64, timelineID: UUID? = nil) -> StoryInterval {
        .point(.init(timelineID: timelineID ?? timeline, tick: tick))
    }
    private func snapshot(_ observations: [Observation]) -> StoryKnowledgeSnapshot {
        let scope = StoryMemoryScope.project(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let lines = observations.enumerated().map { "\($0.offset): \($0.element.quote)\n" }
        let source = lines.joined()
        var offset = 0
        let facts = observations.enumerated().map { index, observation -> StoryFact in
            let line = lines[index], range = offset..<(offset + line.utf16.count)
            defer { offset += line.utf16.count }
            return .init(derivedID: "observation-\(index)", scope: scope, content: observation.content,
                evidence: .init(documentID: scope.documentID, quote: line, utf16Hint: offset),
                discourseRange: range, storyInterval: observation.time, confidence: observation.confidence,
                origin: .deterministic(ruleID: "fixture-explicit-metadata"))
        }
        return .init(scope: scope, source: source, facts: facts,
                     entities: .init(characters: [actor, other], objects: [object]))
    }
    private func candidates(_ value: StoryKnowledgeSnapshot, before: Int? = nil) -> [ContinuityCandidate] {
        ContinuityCandidate.prepare(snapshot: value, before: before ?? value.sourceLength)
    }
    private func knowledge(_ stance: CharacterKnowledge.Stance, fact: String = "문이 열렸다") -> StoryFact.Content {
        .characterKnowledge(.init(characterID: actor.id, fact: fact, stance: stance))
    }
    private func location(_ value: String) -> StoryFact.Content {
        .characterState(.init(characterID: actor.id, field: .location, value: value))
    }
    private func condition(_ value: String) -> StoryFact.Content {
        .objectState(.init(objectID: object.id, field: .condition, value: value))
    }
    private func relationship(_ value: String, reversed: Bool = false) -> StoryFact.Content {
        .relationship(.init(fromID: reversed ? other.id : actor.id, toID: reversed ? actor.id : other.id, value: value))
    }

    func testExplicitUnawareAndKnowsRequireSameFactKnownOverlapAndBothOriginals() throws {
        let value = snapshot([.init(content: knowledge(.unaware), time: at(4), quote: "민준은 문이 열렸다는 사실을 몰랐다."),
                              .init(content: knowledge(.knows), time: at(4), quote: "민준은 문이 열렸다는 사실을 알고 있었다.")])
        let result = candidates(value)
        XCTAssertEqual(result.count, 1)
        let candidate = try XCTUnwrap(result.first)
        XCTAssertEqual(candidate.kind, .knowledgeLeak)
        XCTAssertEqual(candidate.scope, value.scope)
        XCTAssertEqual(candidate.sourceRevision, value.sourceRevision)
        XCTAssertEqual(candidate.subjectID, actor.id)
        XCTAssertEqual(candidate.evidence.count, 2)
        XCTAssertEqual(candidate.factIDs, ["observation-0", "observation-1"])
        XCTAssertTrue(candidate.requiresJudging)
        XCTAssertTrue(candidates(value, before: 1).isEmpty)
        XCTAssertEqual(result, candidates(value))
        for stance: CharacterKnowledge.Stance in [.unknown, .suspects, .misbelieves, .hides, .knows] {
            XCTAssertTrue(candidates(snapshot([.init(content: knowledge(stance), time: at(4)),
                                               .init(content: knowledge(.knows), time: at(4))])).isEmpty)
        }
    }

    func testLocationCandidatesRefuseUnknownDifferentTimelineAndSequentialPositions() {
        XCTAssertEqual(candidates(snapshot([.init(content: location("서울"), time: at(2)),
                                            .init(content: location("부산"), time: at(2))])).first?.kind, .locationOverlap)
        for time in [StoryInterval.unknown, at(3), at(2, timelineID: UUID())] {
            XCTAssertTrue(candidates(snapshot([.init(content: location("서울"), time: at(2)),
                                               .init(content: location("부산"), time: time)])).isEmpty)
        }
        XCTAssertTrue(candidates(snapshot([.init(content: location("서울"), time: at(2)),
                                           .init(content: location("서울"), time: at(2))])).isEmpty)
    }

    func testWeakOrUnknownConfidenceNeverGrantsAnAtomicCandidate() {
        for confidence: Double? in [nil, 0, 0.79] {
            XCTAssertTrue(candidates(snapshot([.init(content: location("서울"), time: at(2), confidence: confidence),
                                               .init(content: location("부산"), time: at(2))])).isEmpty)
        }
    }

    func testObjectReappearanceUsesStoryOrderAndEveryInterveningConditionFencesOldState() {
        let destroyed = Observation(content: condition("파괴됨"), time: at(1))
        let present = Observation(content: condition("온전함"), time: at(3))
        XCTAssertEqual(candidates(snapshot([destroyed, present])).first?.kind, .objectReappearance)
        XCTAssertEqual(candidates(snapshot([present, destroyed])).first?.kind, .objectReappearance, "Discourse flashbacks cannot reverse known story order")
        for middle in [Observation(content: condition("복구됨"), time: at(2)),
                       Observation(content: condition("불확실"), time: at(2), confidence: nil),
                       Observation(content: condition("파괴됨"), time: .unknown)] {
            XCTAssertTrue(candidates(snapshot([destroyed, middle, present])).isEmpty)
        }
        XCTAssertTrue(candidates(snapshot([destroyed, .init(content: condition("온전함"), time: at(3, timelineID: UUID()))])).isEmpty)
    }

    func testRelationshipIdentityRequiresClosedOppositionSameDirectionAndKnownOverlap() {
        for pair in [("동일인", "다른 인물"), ("배우자", "배우자 아님"), ("친부", "친부 아님")] {
            XCTAssertEqual(candidates(snapshot([.init(content: relationship(pair.0), time: at(1)),
                                                .init(content: relationship(pair.1), time: at(1))])).first?.kind, .relationshipIdentity)
        }
        for value in ["친구", "동료", "친부"] {
            XCTAssertTrue(candidates(snapshot([.init(content: relationship("배우자"), time: at(1)),
                                               .init(content: relationship(value), time: at(1))])).isEmpty)
        }
        XCTAssertTrue(candidates(snapshot([.init(content: relationship("동일인"), time: at(1)),
                                           .init(content: relationship("다른 인물", reversed: true), time: at(1))])).isEmpty)
    }

    func testRepeatedLogicalContradictionsGroupOnceAndOutputRemainsBoundedAndOrdered() {
        let repeated = snapshot([.init(content: knowledge(.unaware), time: at(1)), .init(content: knowledge(.knows), time: at(1)),
                                 .init(content: knowledge(.unaware), time: at(1)), .init(content: knowledge(.knows), time: at(1))])
        XCTAssertEqual(candidates(repeated).count, 1)
        var observations: [Observation] = []
        for index in 0..<130 {
            observations += [.init(content: knowledge(.unaware, fact: "사실 \(index)"), time: at(1)),
                             .init(content: knowledge(.knows, fact: "사실 \(index)"), time: at(1))]
        }
        let value = snapshot(observations), result = candidates(value)
        XCTAssertEqual(result.count, 128)
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        XCTAssertEqual(result.map { $0.evidence.last?.utf16Hint ?? -1 }, result.map { $0.evidence.last?.utf16Hint ?? -1 }.sorted())
    }

    func testCancellationDiscardsAllPreparedCandidates() async {
        let value = snapshot([.init(content: location("서울"), time: at(1)), .init(content: location("부산"), time: at(1))])
        let task = Task.detached {
            try? await Task.sleep(for: .seconds(1))
            return ContinuityCandidate.prepare(snapshot: value, before: value.sourceLength)
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.isEmpty)
    }
    func testOriginalEvidenceOrderDoesNotDependOnDerivedCacheKeyOrWideDiscourseRange() throws {
        let scope = StoryMemoryScope.project(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let source = "먼저 서울을 기록했다. 나중에 부산을 기록했다."
        let first = "먼저 서울을 기록했다.", last = "나중에 부산을 기록했다."
        let facts = [("z-first", first, location("서울")), ("a-last", last, location("부산"))].map { key, quote, content in
            StoryFact(derivedID: key, scope: scope, content: content,
                evidence: .init(documentID: scope.documentID, quote: quote, utf16Hint: (source as NSString).range(of: quote).location),
                discourseRange: 0..<source.utf16.count, storyInterval: at(1), confidence: 0.9, origin: .deterministic(ruleID: "fixture"))
        }
        let value = StoryKnowledgeSnapshot(scope: scope, source: source, facts: facts, entities: .init(characters: [actor, other]))
        let candidate = try XCTUnwrap(candidates(value).first)
        XCTAssertEqual(candidate.evidence.map(\.quote), [first, last])
        XCTAssertEqual(candidate.factIDs, ["z-first", "a-last"])
    }

    func testComparisonBudgetRefusesTheWholePassRatherThanPublishingAnEarlyPartial() {
        var observations: [Observation] = [.init(content: knowledge(.unaware), time: at(1)), .init(content: knowledge(.knows), time: at(1))]
        for index in 0..<365 { observations.append(.init(content: relationship("호환되는 역할 \(index)"), time: at(1))) }
        XCTAssertTrue(candidates(snapshot(observations)).isEmpty)
    }

}
