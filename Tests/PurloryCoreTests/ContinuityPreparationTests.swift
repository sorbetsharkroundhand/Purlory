@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
@_spi(Benchmark) @testable import PurloryInference
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ContinuityPreparationTests: XCTestCase {
    private let actor = CharacterCard(name: "민준")
    private let calendar = "explicit-calendar"
    private func ages(_ values: [(Int64, Int64, String)]) -> StoryKnowledgeSnapshot {
        let scope = StoryMemoryScope.project(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let lines = values.enumerated().map { "\($0.offset): \($0.element.1)년 민준은 만 \($0.element.0)세였다.\n" }
        let source = lines.joined(); var offset = 0
        let facts = values.enumerated().map { index, value -> StoryFact in
            let line = lines[index]; defer { offset += line.utf16.count }
            return .init(derivedID: "age-\(index)", scope: scope,
                content: .characterAge(.init(characterID: actor.id, completedYears: value.0, calendarYear: value.1, calendarID: value.2)),
                evidence: .init(documentID: scope.documentID, quote: line, utf16Hint: offset),
                discourseRange: offset..<(offset + line.utf16.count), confidence: 0.9, origin: .deterministic(ruleID: "explicit-age-fixture"))
        }
        return .init(scope: scope, source: source, facts: facts, entities: .init(characters: [actor]))
    }
    private func candidates(_ value: StoryKnowledgeSnapshot) -> [ContinuityCandidate] {
        ContinuityCandidate.prepare(snapshot: value, before: value.sourceLength)
    }

    func testCompletedYearsUseAnExplicitCalendarAndPossibleBirthdayRange() throws {
        let conflict = ages([(20, 2020, calendar), (24, 2021, calendar)])
        let candidate = try XCTUnwrap(candidates(conflict).first)
        XCTAssertEqual(candidate.kind, .ageArithmetic)
        XCTAssertEqual(candidate.evidence.count, 2)
        XCTAssertFalse(candidate.explanation.isEmpty)
        XCTAssertTrue(candidate.requiresJudging)
        XCTAssertTrue(candidates(ages([(20, 2020, calendar), (22, 2022, calendar)])).isEmpty)
        XCTAssertTrue(candidates(ages([(20, 2020, calendar), (22, 2021, calendar)])).isEmpty, "Unknown birthdays permit two birthday crossings across adjacent calendar years")
        XCTAssertTrue(candidates(ages([(20, 2020, calendar), (40, 2021, "another-calendar")])).isEmpty)
    }

    func testNegativeUnknownCalendarAndOverflowCannotCreateAgeClaims() {
        for value: (Int64, Int64, String) in [(-1, 2021, calendar), (24, 2021, ""), (24, 2021, String(repeating: "x", count: 129)), (Int64.max, Int64.min, calendar), (0, Int64.min, calendar)] {
            XCTAssertTrue(candidates(ages([(20, 2020, calendar), value])).isEmpty)
        }
    }

    func testTypedAgeAndExplicitUnawareRoundTripWithoutUpgradingUnknownMetadata() throws {
        let scope = StoryMemoryScope.legacy(documentID: WritingDocumentID())
        let age = CharacterAge(characterID: actor.id, completedYears: 20, calendarYear: 2020, calendarID: calendar)
        let fact = StoryFact(derivedID: "age", scope: scope, content: .characterAge(age),
            evidence: .init(documentID: scope.documentID, quote: "20세", utf16Hint: 0), discourseRange: 0..<3,
            origin: .deterministic(ruleID: "explicit"))
        XCTAssertEqual(try JSONDecoder().decode(StoryFact.self, from: JSONEncoder().encode(fact)), fact)
        XCTAssertNil(fact.confidence)
        XCTAssertEqual(fact.storyInterval, .unknown)
        for stance: CharacterKnowledge.Stance in [.unknown, .unaware] {
            XCTAssertEqual(try JSONDecoder().decode(CharacterKnowledge.Stance.self, from: JSONEncoder().encode(stance)), stance)
        }
    }

    func testLegacyPreparedCandidatesRequireExactCurrentDocumentAndOriginals() throws {
        let source = "# 사건\n민준은 사망했다.\n# 현재\n민준이 말했다. \"돌아왔어요.\""
        let scope = StoryMemoryScope.project(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let snapshot = legacySnapshot(source, scope: scope)
        let warnings = ConsistencyChecker.check(snapshot: snapshot, characters: [actor], source: source)
        let result = ContinuityCandidate.prepare(snapshot: snapshot, warnings: warnings, scope: scope, source: source)
        let candidate = try XCTUnwrap(result.first)
        XCTAssertEqual(candidate.kind, .deadSpeaker)
        XCTAssertEqual(candidate.evidence.count, 2)
        XCTAssertFalse(candidate.requiresJudging, "Closed original legacy check preserves its existing visibility policy")
        XCTAssertTrue(ContinuityCandidate.prepare(snapshot: snapshot, warnings: warnings, scope: .legacy(documentID: scope.documentID), source: source).isEmpty)
        XCTAssertTrue(ContinuityCandidate.prepare(snapshot: snapshot, warnings: warnings, scope: scope, source: source + "追記").isEmpty)
        var unverified = warnings[0]; unverified.evidence = []
        XCTAssertTrue(ContinuityCandidate.prepare(snapshot: snapshot, warnings: [unverified], scope: scope, source: source).isEmpty)
    }

    func testAgeObservationsRemainCharacterIndexedAndExcludeIncompleteDiscourse() throws {
        let value = ages([(20, 2020, calendar), (24, 2021, calendar)])
        XCTAssertEqual(value.observations(of: actor.id, before: value.sourceLength).count, 2)
        let first = try XCTUnwrap(value.observations(before: value.sourceLength).first)
        XCTAssertTrue(ContinuityCandidate.prepare(snapshot: value, before: first.discourseRange.upperBound).isEmpty)
    }

    private func legacySnapshot(_ source: String, scope: StoryMemoryScope) -> KnowledgeSnapshot {
        let outline = DocumentOutline.parse(source), hash = outline.scenes[0].contentHash
        return .init(entryID: scope.documentID.rawValue, outline: outline, summariesByHash: [:],
            storyKnowledge: .init(scope: scope, source: source, facts: [], entities: .init(characters: [actor])),
            events: [hash: [.init(sceneHash: hash, participants: [actor.id], summary: "민준 사망", importance: 5,
                deltas: [.init(characterID: actor.id, field: .vitality, value: "사망", sceneHash: hash)], quote: "민준은 사망했다.")]],
            utterances: DialogueAttribution.utterances(in: source, cards: [actor]), characters: [actor])
    }

    @MainActor
    func testActualHydrationPublishesPreparedCandidatesAndEditPauseTransitionRetireThem() async throws {
        let source = "# 사건\n민준은 사망했다.\n# 현재\n민준이 말했다. \"돌아왔어요.\""
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let scope = StoryMemoryScope.project(projectID: key.projectID, documentID: key.documentID)
        let writer = WriterDocumentData(documentID: key.documentID, characters: [actor])
        let data = [WriterDocumentData.key(for: key.documentID): try writer.encoded()]
        var document = ProjectDocumentSnapshot(identity: .init(key: key, generation: 1), title: "Fixture", body: source,
                                               kind: .manuscript, mode: .fiction, userData: data)
        var sidecar = KnowledgeSidecar(scope: scope)
        let snapshot = legacySnapshot(source, scope: scope)
        for event in snapshot.events { sidecar.events[event.sceneHash, default: []].append(event) }
        let settings = CompletionSettings(); settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(engine: CompletionEngine(), settings: settings, sidecarPersistence: ContinuityFixturePersistence(sidecar))
        reader.attach(documentProvider: { document }); defer { reader.shutdown() }
        for paused in [false, true] {
            let published = expectation(description: "Current original-backed candidate")
            let subscription = reader.continuityCandidatesChanges.dropFirst().filter { !$0.isEmpty }.prefix(1).sink { _ in published.fulfill() }
            reader.setMemoryPressurePaused(false)
            reader.noteDocumentChange(document)
            await fulfillment(of: [published], timeout: 2)
            subscription.cancel()
            XCTAssertEqual(reader.continuityCandidates.first?.scope, scope)
            XCTAssertEqual(reader.continuityCandidates.first?.evidence.count, 2)
            reader.setMemoryPressurePaused(paused)
            if paused { XCTAssertTrue(reader.continuityCandidates.isEmpty, "Pressure retires pending review actions immediately") }
            document = .init(identity: .init(key: key, generation: document.identity.generation + 1), title: "Fixture", body: source,
                             kind: .manuscript, mode: .fiction, userData: data)
            reader.noteDocumentChange(document)
            XCTAssertTrue(reader.continuityCandidates.isEmpty)
        }
        reader.prepareForProjectTransition()
        XCTAssertTrue(reader.continuityCandidates.isEmpty)
    }
    @MainActor
    func testLateNoncooperativeHydrationCannotPublishCandidatesAfterProjectRetirement() async throws {
        let source = "# 사건\n민준은 사망했다.\n# 현재\n민준이 말했다. \"돌아왔어요.\""
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let scope = StoryMemoryScope.project(projectID: key.projectID, documentID: key.documentID)
        let writer = WriterDocumentData(documentID: key.documentID, characters: [actor])
        var document: ProjectDocumentSnapshot? = .init(identity: .init(key: key, generation: 1), title: "Old", body: source,
            kind: .manuscript, mode: .fiction, userData: [WriterDocumentData.key(for: key.documentID): try writer.encoded()])
        var sidecar = KnowledgeSidecar(scope: scope)
        for event in legacySnapshot(source, scope: scope).events { sidecar.events[event.sceneHash, default: []].append(event) }
        let started = expectation(description: "Old read suspended")
        let persistence = ContinuityFixturePersistence(sidecar, started: started)
        let settings = CompletionSettings(); settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        reader.attach(documentProvider: { document }); defer { reader.shutdown() }
        reader.noteDocumentChange(try XCTUnwrap(document))
        await fulfillment(of: [started], timeout: 2)
        reader.prepareForProjectTransition(); document = nil
        let forbidden = expectation(description: "Retired source cannot publish review actions"); forbidden.isInverted = true
        let subscription = reader.continuityCandidatesChanges.dropFirst().filter { !$0.isEmpty }.sink { _ in forbidden.fulfill() }
        await persistence.release()
        await fulfillment(of: [forbidden], timeout: 0.2)
        XCTAssertTrue(reader.continuityCandidates.isEmpty)
        withExtendedLifetime(subscription) {}
    }

}

private actor ContinuityFixturePersistence: KnowledgeSidecarPersisting {
    let value: KnowledgeSidecar
    let started: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ value: KnowledgeSidecar, started: XCTestExpectation? = nil) { self.value = value; self.started = started }
    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar {
        if let started {
            started.fulfill()
            await withCheckedContinuation { continuation = $0 }
        }
        return value
    }
    func release() { continuation?.resume(); continuation = nil }
    func save(_ sidecar: KnowledgeSidecar, pruningTo liveHashes: Set<String>?, scope: StoryMemoryScope) async throws {}
    func replaceWithFresh(scope: StoryMemoryScope, generation: Int) async throws -> KnowledgeSidecar { .init(scope: scope) }
    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {}
}
