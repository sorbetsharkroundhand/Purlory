@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
@_spi(Benchmark) @testable import PurloryInference
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class StoryKnowledgeProjectionTests: XCTestCase {
    private let document = WritingDocumentID(), character = UUID(), other = UUID()
    private let body = "# Scene\n민아는 문이 열렸다는 사실을 알았다.🙂\n"
    private var scope: StoryMemoryScope { .project(projectID: project, documentID: document) }
    private let project = WritingProjectID()
    private var cards: [CharacterCard] { [.init(id: character, name: "민아"), .init(id: other, name: "동생")] }
    private func sidecar(_ body: String? = nil) -> KnowledgeSidecar {
        let outline = DocumentOutline.parse(body ?? self.body), hash = outline.scenes[0].contentHash
        var cache = KnowledgeSidecar(scope: scope)
        cache.events[hash] = [.init(sceneHash: hash, participants: [character], summary: "The door opened", importance: 5,
                                    deltas: [.init(characterID: character, field: .location, value: "door", sceneHash: hash)], quote: "문이 열렸다는")]
        cache.insights[hash] = .init(knowledge: KnowledgeDelta.Stance.allCases.map {
            .init(characterID: character, stance: $0, fact: "secret-\($0.rawValue)", sceneHash: hash, quote: "사실을 알았다")
        }, relations: [.init(fromID: character, toID: other, value: "trusts", sceneHash: hash, quote: "민아는")])
        return cache
    }
    private func prepare(_ cache: KnowledgeSidecar, source: String? = nil, outline: DocumentOutline? = nil) -> StoryKnowledgeSnapshot {
        let source = source ?? body
        return StoryKnowledgeProjection.make(scope: scope, body: source, outline: outline ?? .parse(source), sidecar: cache, characters: cards)
    }

    func testRealLegacyAtomsHaveOriginalEvidenceAndRemainUncertainUntilCompleteScene() throws {
        let outline = DocumentOutline.parse(body), cache = sidecar(), view = prepare(cache)
        let end = try XCTUnwrap(outline.scenes.first).utf16Range.upperBound
        XCTAssertTrue(view.observations(before: end - 1).isEmpty)
        let values = view.observations(before: end)
        XCTAssertEqual(values.count, 7)
        XCTAssertEqual(view, prepare(cache))
        for value in values {
            XCTAssertEqual(value.scope, scope); XCTAssertNil(value.confidence)
            XCTAssertEqual(value.storyInterval, .unknown)
            XCTAssertEqual(value.discourseRange, outline.scenes[0].utf16Range)
            XCTAssertNotNil(SourceAnchor.uniqueOriginalRange(for: value.evidence.quote, in: body, within: NSRange(value.discourseRange)))
            guard case .model = value.origin else { return XCTFail("Legacy output never invents writer authority") }
        }
        let stances = values.compactMap { value -> CharacterKnowledge.Stance? in
            if case .characterKnowledge(let knowledge) = value.content { return knowledge.stance }; return nil
        }
        XCTAssertEqual(Set(stances.map(\.rawValue)), Set(["knows", "suspects", "misbelieves", "hides"]))
        XCTAssertEqual(view.characterState(of: character, field: .location, at: .init(timelineID: UUID(), tick: 100), before: end), .unknown)
    }

    func testRepeatedIdenticalScenesKeepDistinctOriginalPositionsAndDerivedIDs() throws {
        let source = "# Same\n문이 열렸다는 기록.\n# Same\n문이 열렸다는 기록.\n"
        let outline = DocumentOutline.parse(source)
        XCTAssertEqual(outline.scenes.count, 2)
        XCTAssertEqual(outline.scenes[0].contentHash, outline.scenes[1].contentHash)
        var cache = sidecar(source); cache.insights = [:]
        cache.events[outline.scenes[0].contentHash]?[0].deltas = []
        let view = prepare(cache, source: source)
        let first = view.observations(before: outline.scenes[0].utf16Range.upperBound)
        let both = view.observations(before: source.utf16.count)
        XCTAssertEqual(first.count, 1); XCTAssertEqual(both.count, 2)
        XCTAssertEqual(Set(both.map(\.id)).count, 2)
        XCTAssertNotEqual(both.first?.evidence.utf16Hint, both.last?.evidence.utf16Hint)
        XCTAssertEqual(both.first?.id, first.first?.id)
    }

    func testMissingAmbiguousNormalizedAndStaleOriginalsRefuse() {
        var cache = sidecar(); let hash = DocumentOutline.parse(body).scenes[0].contentHash
        cache.insights = [:]
        for quote in [nil, "missing", "한🙂"] as [String?] {
            cache.events[hash]?[0].quote = quote
            XCTAssertTrue(prepare(cache).observations(before: body.utf16.count).isEmpty)
        }
        XCTAssertNil(SourceAnchor.uniqueOriginalRange(for: "aa", in: "aaaa", within: .init(location: 0, length: 4)))
        XCTAssertNil(SourceAnchor.uniqueOriginalRange(for: "한🙂", in: "한🙂", within: .init(location: 0, length: 5)))
        XCTAssertNil(SourceAnchor.uniqueOriginalRange(for: "�", in: "🙂x", within: .init(location: 1, length: 1)))
        XCTAssertNil(SourceAnchor.uniqueOriginalRange(for: "x", in: "x", within: .init(location: Int.max, length: 1)))
        let mixed = "한🙂 한🙂"
        XCTAssertEqual(SourceAnchor.uniqueOriginalRange(for: "한🙂", in: mixed, within: .init(location: 0, length: mixed.utf16.count)), .init(location: 4, length: 5))
        let oldOutline = DocumentOutline.parse(body)
        XCTAssertTrue(prepare(sidecar(), source: body.replacingOccurrences(of: "문이", with: "새 문이"), outline: oldOutline).observations(before: body.utf16.count).isEmpty)
    }

    func testWrongScopeSchemaRecordOwnershipTombstonesAndUnknownSubjectsRefuse() {
        let hash = DocumentOutline.parse(body).scenes[0].contentHash
        var cache = sidecar(); cache.scope = .project(projectID: .init(), documentID: document)
        XCTAssertTrue(prepare(cache).observations(before: body.utf16.count).isEmpty)
        cache = sidecar(); cache.schemaVersion -= 1
        XCTAssertTrue(prepare(cache).observations(before: body.utf16.count).isEmpty)
        cache = sidecar(); cache.insights = [:]
        cache.events[hash]?[0].sceneHash = "tombstone"
        XCTAssertTrue(prepare(cache).observations(before: body.utf16.count).isEmpty)
        cache = sidecar(); cache.insights = [:]
        cache.events["tombstone"] = cache.events.removeValue(forKey: hash)
        XCTAssertTrue(prepare(cache).observations(before: body.utf16.count).isEmpty)
        cache = sidecar(); cache.events[hash]?[0].participants = [UUID()]
        cache.insights[hash]?.knowledge = []; cache.insights[hash]?.relations[0].toID = UUID()
        XCTAssertTrue(prepare(cache).observations(before: body.utf16.count).isEmpty)
        cache = sidecar(); cache.insights = [:]; cache.events[hash]?[0].deltas[0].sceneHash = "wrong"
        XCTAssertEqual(prepare(cache).observations(before: body.utf16.count).count, 1)
    }

    func testRealSnapshotPreservesWriterCorrectionAndOmitsSupersededRawModelClaims() throws {
        let cache = sidecar(), original = cache
        let event = try XCTUnwrap(cache.events.values.first?.first)
        let correction = NarrativeOverride(kind: .eventSummary, key: event.stableKey, value: "Writer correction")
        let snapshot = BackgroundIndexer.makeSnapshot(entryID: document.rawValue, scope: scope, outline: .parse(body), sidecar: cache,
            utterances: [], overrides: [correction], body: body, characters: cards)
        XCTAssertEqual(snapshot.events.first?.summary, correction.value)
        XCTAssertEqual(snapshot.overrides.all, [correction])
        let view = try XCTUnwrap(snapshot.storyKnowledge)
        XCTAssertEqual(view.scope, scope)
        XCTAssertEqual(view.observations(before: body.utf16.count).count, 5)
        XCTAssertEqual(cache, original)
        XCTAssertNil(KnowledgeSnapshot(entryID: document.rawValue, outline: .parse(body), summariesByHash: [:]).storyKnowledge)
    }

    func testSnapshotAttachmentRejectsAnotherDocumentAndEqualityRetainsSourceRevision() {
        let view = prepare(sidecar())
        XCTAssertNil(KnowledgeSnapshot(entryID: UUID(), outline: .parse(body), summariesByHash: [:], storyKnowledge: view).storyKnowledge)
        let a = StoryKnowledgeSnapshot(scope: scope, source: "abc", facts: [], entities: .init(characters: []))
        let b = StoryKnowledgeSnapshot(scope: scope, source: "abd", facts: [], entities: .init(characters: []))
        XCTAssertNotEqual(a, b)
    }

    @MainActor
    func testActualBackgroundHydrationPublishesPreparedBoundaryWithoutModelOrReload() async throws {
        let cache = sidecar(), persistence = StoryProjectionPersistence(cache)
        let data = WriterDocumentData(documentID: document, characters: cards)
        let identity = ProjectRuntimeIdentity(key: .init(projectID: project, documentID: document), generation: 1)
        var input = ProjectDocumentSnapshot(identity: identity, title: "Synthetic", body: body, kind: .manuscript, mode: .fiction,
            userData: [WriterDocumentData.key(for: document): try data.encoded()])
        let settings = CompletionSettings(); settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        reader.attach(documentProvider: { input }); defer { reader.shutdown() }
        let published = expectation(description: "Prepared Story Knowledge published")
        let subscription = reader.snapshotGenerationChanges.dropFirst().prefix(1).sink { _ in published.fulfill() }
        reader.noteDocumentChange(input)
        await fulfillment(of: [published], timeout: 5)
        let view = try XCTUnwrap(reader.snapshot?.storyKnowledge)
        XCTAssertEqual(reader.snapshotRuntimeIdentity, identity)
        XCTAssertEqual(view.observations(before: body.utf16.count).count, 7)
        _ = view.observations(before: body.utf16.count)
        input = ProjectDocumentSnapshot(identity: .init(key: identity.key, generation: 2), title: "Synthetic", body: body + "Edited source.",
            kind: .manuscript, mode: .fiction, userData: input.userData)
        let refreshed = expectation(description: "Changed original retires old observations")
        let refresh = reader.snapshotGenerationChanges.dropFirst().prefix(1).sink { _ in refreshed.fulfill() }
        reader.noteDocumentChange(input)
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(reader.snapshotRuntimeIdentity, input.identity)
        XCTAssertTrue(try XCTUnwrap(reader.snapshot?.storyKnowledge).observations(before: input.body.utf16.count).isEmpty)
        let loads = await persistence.loads
        XCTAssertEqual(loads, 1)
        withExtendedLifetime(subscription) {}
        withExtendedLifetime(refresh) {}
    }

}

private actor StoryProjectionPersistence: KnowledgeSidecarPersisting {
    let cache: KnowledgeSidecar
    private(set) var loads = 0
    init(_ cache: KnowledgeSidecar) { self.cache = cache }
    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar { loads += 1; return cache }
    func save(_ sidecar: KnowledgeSidecar, pruningTo: Set<String>?, scope: StoryMemoryScope) async throws {}
    func replaceWithFresh(scope: StoryMemoryScope, generation: Int) async throws -> KnowledgeSidecar { .init(scope: scope) }
    func pruneLegacyOrphans(keeping: Set<WritingDocumentID>) async {}
}
