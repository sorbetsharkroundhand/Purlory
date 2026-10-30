@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class DuplicateSceneSafetyTests: XCTestCase {
    private let source = "# 반복\n같은 원문\n# 반복\n같은 원문\n# 끝\n마지막 원문\n"
    private func snapshot() -> KnowledgeSnapshot {
        let outline = DocumentOutline.parse(source)
        let repeated = outline.scenes[0].contentHash, final = outline.scenes[2].contentHash
        return KnowledgeSnapshot(entryID: UUID(), outline: outline, summariesByHash: [:], events: [
            repeated: [.init(sceneHash: repeated, participants: [], summary: "반복 사건", importance: 3, quote: "같은 원문")],
            final: [.init(sceneHash: final, participants: [], summary: "마지막 사건", importance: 3, quote: "마지막 원문")]])
    }
    func testRepeatedOriginalScenesDoNotTrapSnapshotConstructionOrCursorQueries() {
        let value = snapshot()
        XCTAssertEqual(value.outline.scenes.count, 3)
        XCTAssertEqual(Set(value.outline.scenes.map(\.contentHash)).count, 2)
        let firstEnd = value.outline.scenes[0].utf16Range.upperBound
        XCTAssertTrue(value.events(before: firstEnd).isEmpty, "A hash cannot identify which repeated occurrence produced derived evidence")
        XCTAssertFalse(value.events(before: source.utf16.count).isEmpty)
    }
    func testSalienceRefusesAnArbitraryOccurrenceIndexForRepeatedHash() {
        let value = snapshot(), scenes = value.outline.scenes
        let scores = value.sceneSalienceScores(at: scenes[2].utf16Range.lowerBound, candidates: scenes)
        XCTAssertTrue(scores.values.allSatisfy(\.isFinite))
        XCTAssertEqual(scores[scenes[0].contentHash], 5, "Ambiguous occurrence has no invented recency distance")
    }
    func testChronologyNeverGivesRepeatedHashAnArbitrarySourceStart() {
        let value = snapshot(), rows = GraphRow.chronoRows(from: value)
        XCTAssertEqual(rows.count, 1)
        guard case .event(_, let event, let start) = rows.first else { return XCTFail("Expected the uniquely located final event") }
        XCTAssertEqual(event.quote, "마지막 원문")
        XCTAssertEqual(start, value.outline.scenes[2].utf16Range.lowerBound)
    }
    func testActualSnapshotCanFeedMapWhileRepeatedSceneActionsStaySourceOwned() async throws {
        let identity = ProjectRuntimeIdentity(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1)
        let scope = StoryMemoryScope.project(projectID: identity.key.projectID, documentID: identity.key.documentID)
        let document = ProjectDocumentSnapshot(identity: identity, title: "Repeated", body: source, kind: .manuscript, mode: .fiction, userData: [:])
        let snapshot = KnowledgeSnapshot(entryID: identity.key.documentID.rawValue, outline: DocumentOutline.parse(source), summariesByHash: [:],
            storyKnowledge: .init(scope: scope, source: source, facts: [], entities: .init(characters: [])))
        let map = try await StoryMapProjection.build(document, knowledge: snapshot, knowledgeOrigin: identity, order: .chronology)
        XCTAssertEqual(map.rows.count, 3)
        XCTAssertEqual(Set(map.rows.map(\.id)).count, 3)
        XCTAssertEqual(map.rows.map(\.evidence.utf16Hint), snapshot.outline.scenes.map { $0.utf16Range.lowerBound })
    }
    func testUniqueSceneChronologyAndSalienceRemainAvailable() {
        let body = "# 하나\n원문 하나\n# 둘\n원문 둘\n", outline = DocumentOutline.parse(body)
        let events = Dictionary(uniqueKeysWithValues: outline.scenes.enumerated().map { index, scene in
            (scene.contentHash, [StoryEvent(sceneHash: scene.contentHash, participants: [], summary: "event \(index)", importance: 3)])
        })
        let value = KnowledgeSnapshot(entryID: UUID(), outline: outline, summariesByHash: [:], events: events)
        XCTAssertEqual(GraphRow.chronoRows(from: value).count, 2)
        let scores = value.sceneSalienceScores(at: outline.scenes[1].utf16Range.lowerBound, candidates: outline.scenes)
        XCTAssertEqual(scores[outline.scenes[0].contentHash], 4.75)
    }
}
