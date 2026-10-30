@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 지식 스냅샷 표준 질의 회귀 테스트 (PLAN §8·§11).
/// 예측 경로가 매 요청마다 부르는 질의들 — 시점 차단·장면 앵커·한국어 말투
/// 프로필이 규격대로 접히는지 고정한다. 상태 델타 fold는 StateDeltaTests,
/// 앎·관계는 NarrativeIntelligenceTests가 담당한다.
final class SnapshotQueriesTests: XCTestCase {

    private let seoyeon = UUID()
    private let minjun = UUID()
    private let dowoon = UUID()

    /// "# A\n가.\n# B\n나.\n# C\n다.\n" — A: 0..<7, B: 7..<14, C: 14..<21
    private var outline: DocumentOutline {
        DocumentOutline.parse("# A\n가.\n# B\n나.\n# C\n다.\n")
    }

    @discardableResult
    private func makeSnapshot(
        events: [String: [StoryEvent]] = [:],
        utterances: [Utterance] = [],
        sceneSummaries: [String: KnowledgeSidecar.SceneSummary] = [:]
    ) -> KnowledgeSnapshot {
        KnowledgeSnapshot(
            entryID: UUID(),
            outline: outline,
            summariesByHash: [:],
            events: events,
            utterances: utterances,
            sceneSummaries: sceneSummaries,
            characters: [])
    }

    private func utterance(
        _ speaker: UUID, _ text: String, at offset: Int,
        listener: UUID? = nil, politeness: Politeness? = nil
    ) -> Utterance {
        Utterance(
            speakerID: speaker, text: text, utf16Start: offset,
            listenerID: listener, politeness: politeness)
    }

    // MARK: - 시점 차단 질의

    func test커서_이전에_끝난_씬의_사건만() throws {
        let scenes = outline.scenes
        let eventInA = StoryEvent(
            sceneHash: scenes[0].contentHash, participants: [seoyeon], summary: "첫 사건", importance: 3)
        let eventInC = StoryEvent(
            sceneHash: scenes[2].contentHash, participants: [seoyeon], summary: "마지막 사건", importance: 3)
        let snapshot = makeSnapshot(events: [
            scenes[0].contentHash: [eventInA], scenes[2].contentHash: [eventInC],
        ])

        // 커서가 B 안(예: 10) — A(끝 7 ≤ 10)만 보인다. C는 미래라 차단.
        XCTAssertEqual(snapshot.events(before: 10).map(\.summary), ["첫 사건"])
        XCTAssertEqual(snapshot.events(before: 30).count, 2)

        // lastAppearance — 역색인을 뒤에서부터 훑어 첫 적중에서 끝난다.
        XCTAssertEqual(
            snapshot.lastAppearance(of: seoyeon, before: 30)?.summary, "마지막 사건")
        XCTAssertEqual(
            snapshot.lastAppearance(of: seoyeon, before: 10)?.summary, "첫 사건")
        XCTAssertNil(snapshot.lastAppearance(of: dowoon, before: 30))
    }

    // MARK: - 장면 앵커 (그라운딩)

    func test장면_동석자는_발화먼저_사건이_다음_순서다() throws {
        let scenes = outline.scenes
        let bHash = try XCTUnwrap(scenes[1].contentHash as String?)
        let utterances = [
            utterance(seoyeon, "어서 와요.", at: 8, listener: minjun),
            utterance(minjun, "고마워.", at: 9),
        ]
        let event = StoryEvent(
            sceneHash: bHash, participants: [dowoon], summary: "B 사건", importance: 3)
        let snapshot = makeSnapshot(
            events: [bHash: [event]], utterances: utterances)

        // 커서가 발화 뒤 — 발화 인물이 먼저고, 사건 참여자는 그 다음.
        // (대화 내부 참여자 순서는 index가 Set으로 모아 순서를 보장하지 않는다.)
        let cohabitants = snapshot.sceneCohabitants(at: 12)
        XCTAssertEqual(Set(cohabitants), [seoyeon, minjun, dowoon])
        XCTAssertEqual(cohabitants.last, dowoon)
        // 커서가 발화 시작 전 — 발화는 위치 신호가 없으니 사건 참여자만.
        XCTAssertEqual(snapshot.sceneCohabitants(at: 8), [dowoon])
    }

    // MARK: - 한국어 말투 (PLAN §6.4 매트릭스)

    func test말투_프로필은_다수결과_최근_예문이다() throws {
        let mine = [
            utterance(seoyeon, "다녀오겠습니다", at: 8, politeness: .honorific),
            utterance(seoyeon, "어서 와", at: 9, politeness: .plain),
            utterance(seoyeon, "잘 계셨습니까", at: 10, politeness: .honorific),
        ]
        let snapshot = makeSnapshot(utterances: mine)

        let profile = try XCTUnwrap(
            snapshot.speechProfile(of: seoyeon, before: 20))

        XCTAssertEqual(profile.defaultPoliteness, .honorific) // 2:1 다수결
        XCTAssertEqual(profile.examples, ["어서 와", "잘 계셨습니까"]) // 최근 2개 순서 유지
        XCTAssertNil(snapshot.speechProfile(of: dowoon, before: 20))
    }

    func test존대_매트릭스는_방향별로_접는다() {
        let utterances = [
            utterance(seoyeon, "안녕하십니까", at: 8, listener: minjun, politeness: .honorific),
            utterance(seoyeon, "감사합니다", at: 9, listener: minjun, politeness: .honorific),
            utterance(minjun, "그래, 왔어", at: 10, listener: seoyeon, politeness: .plain),
        ]
        let snapshot = makeSnapshot(utterances: utterances)

        XCTAssertEqual(
            snapshot.honorific(from: seoyeon, to: minjun, before: 20), .honorific)
        XCTAssertEqual(
            snapshot.honorific(from: minjun, to: seoyeon, before: 20), .plain)
        XCTAssertNil(snapshot.honorific(from: seoyeon, to: dowoon, before: 20))
    }

    // MARK: - 시간 순서 (요구사항 §7 상대 시간 표현)

    func test회상_씬은_시간순서에서_맨앞으로() throws {
        let scenes = outline.scenes
        let bHash = try XCTUnwrap(scenes[1].contentHash as String?)
        // B만 '회상' — 과거 블록 하나가 담화 순서 가운데 끼어 있다.
        let snapshot = makeSnapshot(sceneSummaries: [
            bHash: .init(
                contentHash: bHash, headingPath: ["B"], summary: "회상 씬",
                narrativeType: "회상"),
        ])

        XCTAssertEqual(snapshot.chronologicalSceneOrder(), [1, 0, 2])
    }
}
