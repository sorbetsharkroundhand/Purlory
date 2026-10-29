@testable import PurloryDocumentEngine
import XCTest
@testable import PurloryCore

final class StoryMapProjectionTests: XCTestCase {
    private let person = CharacterCard(name: "민준")
    private func document(_ source: String) -> ProjectDocumentSnapshot {
        .init(identity: .init(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1),
              title: "Novel", body: source, kind: .manuscript, mode: .fiction, userData: [:])
    }
    private func fixture(source: String = "# 밤\n민준은 문을 열었다.\n# 아침\n민준은 떠났다.\n", quote: String? = nil, wrongScope: Bool = false, reverse: Bool = false, firstOnly: Bool = false, customSceneTitle: String? = nil) -> (ProjectDocumentSnapshot, KnowledgeSnapshot) {
        let identity = ProjectRuntimeIdentity(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1)
        let document = ProjectDocumentSnapshot(identity: identity, title: "Novel", body: source, kind: .manuscript, mode: .fiction, userData: [:])
        let scope = StoryMemoryScope.project(projectID: wrongScope ? WritingProjectID() : identity.key.projectID, documentID: identity.key.documentID)
        let outline = DocumentOutline.parse(source)
        let events = outline.scenes.enumerated().map { index, scene in
            StoryEvent(sceneHash: scene.contentHash, participants: firstOnly && index > 0 ? [] : [person.id], summary: "사건 \(index)", importance: 1,
                       quote: quote ?? (index == 0 ? "민준은 문을 열었다." : "민준은 떠났다."))
        }
        let threads = PlotThreadAnalysis(threads: [.init(stableID: "plot", title: "여정", memberships: (firstOnly ? Array(events.prefix(1)) : events).map { .init(eventKey: $0.stableKey) })])
        let knowledge = KnowledgeSnapshot(entryID: identity.key.documentID.rawValue, outline: outline, summariesByHash: [:],
            storyKnowledge: .init(scope: scope, source: source, facts: [], entities: .init(characters: [person])),
            events: Dictionary(grouping: events, by: \.sceneHash),
            eventGraph: reverse ? .init(chronoEdges: [.init(aKey: events[1].stableKey, bKey: events[0].stableKey, relation: .before)]) : nil, plotThreadAnalysis: threads, characters: [person],
            overrides: customSceneTitle.map { .init([.init(kind: .sceneTitle, key: outline.scenes[0].contentHash, value: $0)]) } ?? .empty)
        return (document, knowledge)
    }
    func testReusesNarrativeGraphDeterministicallyWithOriginalEventsAndLaneMembership() async throws {
        let (document, knowledge) = fixture()
        let first = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity)
        let second = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity)
        XCTAssertEqual(first, second)
        let events = first.rows.filter { $0.kind == .event }
        XCTAssertEqual(events.map(\.id), knowledge.canonicalEvents.map { "event:" + $0.canonicalKey })
        XCTAssertEqual(events.map(\.evidence.quote), ["민준은 문을 열었다.", "민준은 떠났다."])
        XCTAssertTrue(events.allSatisfy { !$0.laneSlots.isEmpty && $0.threadIDs.contains("plot") })
        XCTAssertEqual(first.characters.map(\.id), [person.id])
        XCTAssertEqual(first.scenes.count, 2)
    }
    func testVerifiedWriterSceneTitleSurvivesReadOnlyProjectionWithoutChangingSourceIdentity() async throws {
        let (document, knowledge) = fixture(customSceneTitle: "작가가 정한 장면")
        let result = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity)
        XCTAssertEqual(result.scenes.first?.title, "작가가 정한 장면")
        XCTAssertEqual(result.scenes.first?.id, "scene:0")
        XCTAssertEqual(result.scenes.first?.evidence.quote, "# 밤\n")
        let unowned = try await StoryMapProjection.build(document, knowledge: knowledge)
        XCTAssertEqual(unowned.scenes.first?.title, "밤")
    }
    func testFiltersIntersectWithoutChangingSourceOrProjectionOrder() async throws {
        let (document, knowledge) = fixture()
        let projection = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity)
        let filtered = projection.filtered(threadID: "plot", characterID: person.id)
        XCTAssertEqual(filtered.map(\.id), projection.rows.map(\.id))
        XCTAssertTrue(projection.filtered(threadID: "missing", characterID: person.id).isEmpty)
        XCTAssertTrue(projection.filtered(threadID: "plot", characterID: UUID()).isEmpty)
        let chrono = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity, order: .chronology)
        XCTAssertEqual(chrono.rows.filter { $0.kind == .event }.map(\.id), knowledge.eventChronoOrder.map { "event:" + $0 })
    }
    func testNontrivialFiltersAndExplicitChronologyReuseExistingStableOrder() async throws {
        let (document, knowledge) = fixture(reverse: true, firstOnly: true)
        let projection = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity)
        let filtered = projection.filtered(threadID: "plot", characterID: person.id)
        XCTAssertEqual(filtered.map(\.kind), [.scene, .event])
        XCTAssertEqual(filtered.last?.evidence.quote, "민준은 문을 열었다.")
        let chrono = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity, order: .chronology)
        XCTAssertEqual(chrono.rows.map(\.evidence.quote), ["민준은 떠났다.", "민준은 문을 열었다."])
        let unavailable = try await StoryMapProjection.build(document, knowledge: knowledge,
            knowledgeOrigin: .init(key: document.identity.key, generation: document.identity.generation + 1))
        XCTAssertFalse(unavailable.rows.contains { $0.kind == .event })
    }
    func testOversizedGraphFallsBackToScenesWithoutPartialEventAuthority() async throws {
        let document = document("# 사건\n민준은 떠났다.\n")
        let outline = DocumentOutline.parse(document.body), hash = try XCTUnwrap(outline.scenes.first).contentHash
        let scope = StoryMemoryScope.project(projectID: document.identity.key.projectID, documentID: document.identity.key.documentID)
        let events = (0..<8193).map { StoryEvent(sceneHash: hash, participants: [], summary: "event \($0)", importance: 3, quote: "민준은 떠났다.") }
        let snapshot = KnowledgeSnapshot(entryID: document.identity.key.documentID.rawValue, outline: outline, summariesByHash: [:],
            storyKnowledge: .init(scope: scope, source: document.body, facts: [], entities: .init(characters: [])), events: [hash: events])
        let result = try await StoryMapProjection.build(document, knowledge: snapshot, knowledgeOrigin: document.identity)
        XCTAssertEqual(result.rows.map(\.kind), [.scene])
        XCTAssertTrue(result.threads.isEmpty)
    }
    func testModelFreeScenesAndCurrentSceneUseSourceOffsetsRatherThanContentIdentity() async throws {
        let document = document("# 반복\n같은 원문\n# 반복\n같은 원문\n")
        let projection = try await StoryMapProjection.build(document)
        XCTAssertEqual(projection.rows.count, 2)
        XCTAssertNotEqual(projection.rows.first?.id, projection.rows.last?.id)
        let offset = DocumentOutline.parse(document.body).scenes[1].utf16Range.lowerBound
        XCTAssertEqual(projection.currentScene(at: offset)?.id, "scene:\(offset)")
        XCTAssertNil(projection.currentScene(at: -1))
        XCTAssertNil(projection.currentScene(at: document.body.utf16.count + 1))
    }
    func testWrongScopeRevisionOriginAndUnresolvableOriginalCannotAuthorizeEvents() async throws {
        let (document, badScope) = fixture(wrongScope: true)
        let scoped = try await StoryMapProjection.build(document, knowledge: badScope, knowledgeOrigin: document.identity)
        XCTAssertFalse(scoped.rows.contains { $0.kind == .event })
        let (_, knowledge) = fixture()
        let foreign = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity)
        XCTAssertFalse(foreign.rows.contains { $0.kind == .event })
        let (current, missing) = fixture(quote: "민준은 날아갔다.")
        let unresolved = try await StoryMapProjection.build(current, knowledge: missing, knowledgeOrigin: current.identity)
        XCTAssertFalse(unresolved.rows.contains { $0.kind == .event })
        let changed = ProjectDocumentSnapshot(identity: current.identity, title: current.title, body: current.body + "changed", kind: .manuscript, mode: .fiction, userData: [:])
        let stale = try await StoryMapProjection.build(changed, knowledge: missing, knowledgeOrigin: current.identity)
        XCTAssertFalse(stale.rows.contains { $0.kind == .event })
    }
    func testCanonicalEquivalentAndDuplicateQuotesDoNotGrantOriginalAuthority() async throws {
        for (source, quote) in [("# 제목\n한\n", "한"), ("# 제목\n반복 반복\n", "반복")] {
            let (document, knowledge) = fixture(source: source, quote: quote)
            let projection = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity)
            XCTAssertFalse(projection.rows.contains { $0.kind == .event })
        }
    }
    func testDuplicateSceneHashesUseSourceScenesWithoutConstructingLegacyUniqueKeySnapshot() async throws {
        let document = document("# 반복\n같은 원문\n# 반복\n같은 원문\n")
        XCTAssertEqual(Set(DocumentOutline.parse(document.body).scenes.map(\.contentHash)).count, 1)
        let result = try await StoryMapProjection.build(document, order: .chronology)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertFalse(result.rows.contains { $0.kind == .event })
    }
    func testCancelledAndGeneralOrNonManuscriptInputsDoNotProduceMapActions() async throws {
        let (document, _) = fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StoryMapProjection.build(document)
        }
        do { _ = try await task.value; XCTFail("Cancelled preparation must refuse") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let general = ProjectDocumentSnapshot(identity: document.identity, title: document.title, body: document.body, kind: .manuscript, mode: .general, userData: [:])
        let projection = try await StoryMapProjection.build(general)
        XCTAssertTrue(projection.rows.isEmpty)
        let note = ProjectDocumentSnapshot(identity: document.identity, title: document.title, body: document.body, kind: .note, mode: .fiction, userData: [:])
        let noteMap = try await StoryMapProjection.build(note)
        XCTAssertTrue(noteMap.rows.isEmpty)
    }
}
