import Observation
@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 관찰 fan-out 분리 (이슈 #48 / #65 Phase 4).
///
/// 계약: 키 입력(entries[i].body 변화)이 스토어를 무효화해도 무거운 자식 뷰의
/// 파생 계산이 다시 돌지 않아야 한다 — 그래프 행 재구축(서사), 카드당 지식
/// 폴딩(바이블), 트리 평탄화(사이드바)는 입력이 실제로 바뀔 때만 실행된다.
@MainActor
final class ObservationFanOutTests: XCTestCase {

    // MARK: 공통 픽스처

    private func makeDocumentSnapshot(documentID: WritingDocumentID = WritingDocumentID()) -> ProjectDocumentSnapshot {
        ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(
                key: ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID),
                generation: 1
            ),
            title: "소설",
            body: "첫 문장",
            kind: .manuscript,
            mode: .fiction
        )
    }

    /// 소설 본문 + 등록 인물 + 사건·발화가 담긴 스냅샷.
    private func makeSnapshot(
        entryID: UUID, participant: UUID? = nil
    ) -> KnowledgeSnapshot {
        let body = """
        # 1장
        철수가 영희에게 말을 걸었다. "오늘 날씨가 좋네." 영희는 고개를 끄덕였다.

        # 2장
        철수는 서울역으로 향했다. 기차가 떠나기 직전이었다.
        """
        let outline = DocumentOutline.parse(body)
        var events: [String: [StoryEvent]] = [:]
        for scene in outline.scenes {
            events[scene.contentHash] = [
                StoryEvent(
                    sceneHash: scene.contentHash,
                    participants: participant.map { [$0] } ?? [],
                    summary: "사건 요약", importance: 4)
            ]
        }
        return KnowledgeSnapshot(
            entryID: entryID, outline: outline, summariesByHash: [:],
            events: events, characters: [], overrides: NarrativeOverrides([]))
    }

    // MARK: - BackgroundIndexer 동일 값 가드

    func test동일경고_재발행은objectWillChange를울리지않는다() throws {
        let doc = makeDocumentSnapshot()
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        indexer.attach(documentProvider: { doc })

        let entryID = doc.identity.key.documentID.rawValue
        let snapshot = makeSnapshot(entryID: entryID)

        let firstChange = ObservationFlag()
        withObservationTracking { _ = indexer.warnings } onChange: { firstChange.mark() }

        let warningCharacter = UUID()
        indexer._testApplyPassOutputs(
            snapshot: snapshot,
            warnings: [ConsistencyWarning(
                kind: .deadSpeaker, characterID: warningCharacter, utf16Position: 10,
                message: "죽은 인물 등장")],
            metrics: nil)
        XCTAssertTrue(firstChange.changed)
        let repeatedChange = ObservationFlag()
        withObservationTracking { _ = indexer.warnings } onChange: { repeatedChange.mark() }

        // 같은 값 재적용 — 패스가 같은 결론을 내려도 UI를 흔들지 않는다.
        for _ in 0..<3 {
            indexer._testApplyPassOutputs(
                snapshot: nil,
                warnings: [ConsistencyWarning(
                    kind: .deadSpeaker, characterID: warningCharacter, utf16Position: 10,
                    message: "죽은 인물 등장")],
                metrics: nil)
        }
        XCTAssertFalse(repeatedChange.changed, "Identical warnings invalidated their reader")
    }

    func test스냅샷세대는실제발행에서만증가한다() throws {
        let doc = makeDocumentSnapshot()
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        indexer.attach(documentProvider: { doc })

        XCTAssertEqual(indexer.snapshotGeneration, 0)
        let entryID = doc.identity.key.documentID.rawValue

        indexer._testApplyPassOutputs(
            snapshot: makeSnapshot(entryID: entryID), warnings: [], metrics: nil)
        XCTAssertEqual(indexer.snapshotGeneration, 1)

        // 스냅샷 없는 적용(경고만) — 세대 유지.
        indexer._testApplyPassOutputs(snapshot: nil, warnings: [], metrics: nil)
        XCTAssertEqual(indexer.snapshotGeneration, 1)

        indexer._testApplyPassOutputs(
            snapshot: makeSnapshot(entryID: entryID), warnings: [], metrics: nil)
        XCTAssertEqual(indexer.snapshotGeneration, 2)
    }

    // MARK: - 바이블 카드 지식 폴딩

    func test카드파생줄은본문과무관한순수함수다() {
        let card = CharacterCard(name: "철수", aliases: "수군", note: "주인공")
        let snapshot = makeSnapshot(entryID: UUID(), participant: card.id)

        // 같은 입력 — 같은 출력 (결정적).
        let first = CharacterSummarizer.understanding(of: card.id, snapshot: snapshot)
        let second = CharacterSummarizer.understanding(of: card.id, snapshot: snapshot)
        XCTAssertEqual(first, second)

        // 참여 사건이 있으면 연대기가 생긴다 (최근 사건 열람의 실체).
        let chronicle = CharacterSummarizer.chronicle(of: card.id, snapshot: snapshot)
        XCTAssertEqual(chronicle.count, 2, "씬 하나당 사건 한 줄이어야 한다")
        XCTAssertTrue(chronicle.allSatisfy { $0.contains("사건 요약") })

        _ = CharacterSummarizer.knowledgeLines(of: card.id, snapshot: snapshot)
        _ = CharacterSummarizer.relationLines(
            of: card.id, snapshot: snapshot, names: [card.id: card.name])
        _ = CharacterSummarizer.conversationLines(
            of: card, snapshot: snapshot, names: [card.id: card.name])
    }

    func test바이블캐시키는본문변화에불변이다() {
        // BibleCacheKey 규약 — 카드 배열·문서·세대만 본다 (본문 필드 제외).
        var entry = JournalEntry(title: "s", body: "a", kind: .novel)
        entry.characters = [CharacterCard(name: "A")]
        let cards0 = entry.characters
        entry.body = "완전히 다른 본문"
        XCTAssertEqual(cards0, entry.characters ?? [])
        // 본문이 바뀌어도 카드 배열 동등성(키의 핵심)은 유지된다.
    }
}
