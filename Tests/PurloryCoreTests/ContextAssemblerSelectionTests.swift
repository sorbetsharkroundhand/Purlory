@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// ContextAssembler의 사용자 결정(Pin) 규율과 stableKey 고유성 검증.
///
/// - Pin은 "항상 실린다"가 계약이다(§31) — 상한(maxCards)이 사용자 지정을
///   이기면 인스펙터에서 고정한 항목이 말없이 사라져 신뢰가 깨진다.
/// - stableKey는 오버라이드의 키다 — 두 항목이 같은 키를 쓰면 Pin/Exclude가
///   서로를 덮어 "인스펙터가 보는 것 = 조립이 하는 것"(§6.5)이 무너진다.
final class ContextAssemblerSelectionTests: XCTestCase {

    // MARK: - 카드 선택 (Pin은 상한을 이긴다)

    private func cards(_ names: [String]) -> [CharacterCard] {
        names.map { CharacterCard(name: $0) }
    }

    func test_핀카드가_상한보다_많아도_전부_실린다() {
        let all = cards(["가", "나", "다", "라", "마"])
        let pins = Set(all.prefix(4).map { "card|\($0.id.uuidString)" })
        let chosen = ContextAssembler.selectCards(
            from: all, window: "", controls: .init(pins: pins))
        XCTAssertEqual(
            Set(chosen.map(\.name)), ["가", "나", "다", "라"],
            "Pin 4장은 maxCards(3)를 넘어도 전부 실린다 — 사용자 지정이 휴리스틱 예산을 이긴다")
    }

    func test_핀_뒤_남는자리는_언급카드로_채운다() {
        let all = cards(["서연", "민준", "도윤", "하늘", "지우"])
        let pins = Set([all[3]].map { "card|\($0.id.uuidString)" })  // "하늘"만 고정
        let chosen = ContextAssembler.selectCards(
            from: all, window: "지우가 고개를 끄덕였다", controls: .init(pins: pins))
        XCTAssertEqual(Set(chosen.map(\.name)), ["서연", "하늘", "지우"])
    }

    func test_핀없으면_기존규칙_문서순_상한채움() {
        let all = cards(["서연", "민준", "도윤", "하늘", "지우"])
        let chosen = ContextAssembler.selectCards(from: all, window: "")
        XCTAssertEqual(chosen.map(\.name), ["서연", "민준", "도윤"])
    }

    // MARK: - 흐름 사건 stableKey

    /// 씬 3개 — 2장이 회상 구간(남편 소속), 남편 참여 사건 2개.
    private func flashbackSnapshot() -> (KnowledgeSnapshot, DocumentOutline, UUID) {
        let body = """
            # 1장
            남편은 아침을 먹었다. 아내가 커피를 내렸다.

            # 2장
            남편이 어린 시절을 떠올렸다. 그날의 여름은 길고 뜨거웠다.

            # 3장
            진실이 드러났다. 남편은 고개를 떨궜다.
            """
        let outline = DocumentOutline.parse(body)
        let h2 = outline.scenes[1].contentHash
        let 남편 = CharacterCard(name: "남편")
        // 같은 인물이 참여한 사건 2개 — 인물 흐름 파생의 최소 조건(2개↑).
        let events = [
            StoryEvent(sceneHash: h2, participants: [남편.id], summary: "우물가의 여름", importance: 3),
            StoryEvent(sceneHash: h2, participants: [남편.id], summary: "아버지와의 다툼", importance: 3),
        ]
        let segments = SceneSegmentation(segments: [
            NarrativeSegment(
                sceneHash: h2, localStart: 0, localEnd: 500,
                startQuote: "남편이 어린 시절을 떠올렸다",
                layer: .flashback, depth: 1, subjectCharacter: "남편")
        ])
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            events: [h2: events], segments: [h2: segments],
            characters: [남편])
        return (snapshot, outline, 남편.id)
    }

    func test_흐름사건_stableKey가_사건마다_고유다() {
        let (snapshot, outline, _) = flashbackSnapshot()
        var report: [ContextReport.Item] = []
        // 회상 구간 안 커서 — writingInPast + 인물 흐름.
        let cursor = outline.scenes[1].utf16Range.lowerBound + 5
        _ = ContextAssembler.knowledgeText(
            snapshot, before: cursor,
            position: snapshot.position(at: cursor),
            controls: .init(snapshot), report: &report)
        let flowItems = report.filter { $0.kind == .flowEvent }
        XCTAssertEqual(flowItems.count, 2, "흐름의 두 사건이 모두 주입돼야 한다")
        XCTAssertEqual(
            Set(flowItems.map(\.stableKey)).count, flowItems.count,
            "stableKey가 겹치면 한쪽의 Pin/Exclude가 다른 쪽까지 덮는다")
        XCTAssertTrue(
            flowItems.allSatisfy { $0.stableKey.hasPrefix("flow|") },
            "키는 정본 사건 키를 포함해 인스펙터에서 개별 지정 가능해야 한다")
    }

    // MARK: - 산문 렌더링 (PLAN §11 형식 개편 — 레코드 덤프 폐지)

    func test_KoreanProse_받침_판정() {
        XCTAssertTrue(KoreanProse.hasFinalConsonant("민준"))   // ㄴ
        XCTAssertFalse(KoreanProse.hasFinalConsonant("지우"))  // ㅇ 없음
        XCTAssertEqual(KoreanProse.topic("서연"), "서연은")
        XCTAssertEqual(KoreanProse.topic("지우"), "지우는")
        XCTAssertEqual(KoreanProse.copula("불안"), "불안이다")
        XCTAssertEqual(KoreanProse.copula("기대"), "기대다")
        XCTAssertEqual(KoreanProse.terminated("떠났다."), "떠났다.")
        XCTAssertEqual(KoreanProse.terminated("떠났다"), "떠났다.")
    }

    /// 앎·관계 픽스처 — 서연이 민준의 비밀을 숨기고 있다.
    private func insightSnapshot() -> (KnowledgeSnapshot, DocumentOutline) {
        let body = """
            # 1장
            민준은 서연에게 거짓말을 했다. 서연은 눈치채지 못했다.
            """
        let outline = DocumentOutline.parse(body)
        let h1 = outline.scenes[0].contentHash
        let 서연 = CharacterCard(name: "서연")
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            insights: [
                h1: SceneInsights(knowledge: [
                    KnowledgeDelta(
                        characterID: 서연.id, stance: .hides,
                        fact: "민준이 거짓말을 했다", sceneHash: h1)
                ])
            ],
            characters: [서연])
        return (snapshot, outline)
    }

    func test_앎이_태도문장으로_실린다() {
        let (snapshot, outline) = insightSnapshot()
        var report: [ContextReport.Item] = []
        let header = ContextAssembler.headerText(
            document: DocumentContext(
                title: "시험작", kind: .novel,
                characters: snapshot.characters),
            window: "", knowledge: snapshot,
            windowStart: outline.scenes[0].utf16Range.upperBound,
            report: &report)
        XCTAssertTrue(header.contains("서연은 숨기고 있다 — 민준이 거짓말을 했다."), header)
        XCTAssertFalse(header.contains("("), "태도 튜플 `사실(태도)`는 사라진다")
        XCTAssertTrue(report.contains { $0.kind == .knowledge })
    }

    // MARK: - 그라운딩 (동석 인물)

    func test_동석인물이_그라운딩으로_실린다() {
        let body = """
            # 1장
            서연은 집에 있었다.

            # 2장
            민준이 병원에 들렀다. 서연과 이야기를 나눴다.
            """
        let outline = DocumentOutline.parse(body)
        let 서연 = CharacterCard(name: "서연")
        let 민준 = CharacterCard(name: "민준")
        let utterance = Utterance(
            speakerID: 민준.id, text: "괜찮아?",
            utf16Start: outline.scenes[1].utf16Range.lowerBound + 10,
            listenerID: 서연.id, politeness: nil)
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            utterances: [utterance], characters: [서연, 민준])
        var report: [ContextReport.Item] = []
        let block = ContextAssembler.currentSceneText(
            snapshot, document: DocumentContext(
                title: "시험작", kind: .novel, characters: [서연, 민준]),
            cursor: outline.scenes[1].utf16Range.lowerBound + 25,
            controls: ContextAssembler.Controls(nil), report: &report)
        XCTAssertTrue(block.contains("이 장면의 사람들: "), block)
        XCTAssertTrue(block.contains("서연"), block)
        XCTAssertTrue(report.contains { $0.kind == .cohort && $0.stableKey == "cohort" })
    }

    func test_커서_이전_발화만_동석에_든다() {
        // 커서 뒤 발화의 참여자는 아직 "함께 있는" 것이 아니다 — 미래 누출 차단.
        let body = "# 1장\n서연은 창밖을 봤다."
        let outline = DocumentOutline.parse(body)
        let 서연 = CharacterCard(name: "서연")
        let 민준 = CharacterCard(name: "민준")
        let lateUtterance = Utterance(
            speakerID: 민준.id, text: "늦었네", utf16Start: 500,
            listenerID: nil, politeness: nil)
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            utterances: [lateUtterance], characters: [서연, 민준])
        XCTAssertEqual(snapshot.sceneCohabitants(at: 10), [], "커서 앞 10자엔 발화가 없다")
    }

    // MARK: - 살라이언스 선별 (인과 선후관 > 담화 거리)

    func test_인과선행씬이_거리보다_이긴다() {
        // 씬3(현재)의 원인이 된 사건은 멀어도(씬1), 가까운 무관한 씬2보다 먼저 담긴다.
        let body = """
            # 1장
            남편은 서류를 숨겼다. 아무도 몰랐다.

            # 2장
            남편이 산책을 했다. 날씨가 좋았다.

            # 3장
            감사가 문을 두드렸다. 남편은 얼어붙었다.
            """
        let outline = DocumentOutline.parse(body)
        let hashes = outline.scenes.map(\.contentHash)
        let 남편 = CharacterCard(name: "남편")
        let 원인 = StoryEvent(sceneHash: hashes[0], participants: [남편.id],
                             summary: "서류를 숨겼다", importance: 4)
        let 무관 = StoryEvent(sceneHash: hashes[1], participants: [],
                             summary: "산책을 했다", importance: 4)
        let 결과 = StoryEvent(sceneHash: hashes[2], participants: [남편.id],
                             summary: "감사가 찾아왔다", importance: 5)
        let graph = EventGraphAnalysis(causalLinks: [
            CausalLink(fromKey: 원인.stableKey, toKey: 결과.stableKey, kind: .causes)
        ])
        let summaries = Dictionary(uniqueKeysWithValues:
            hashes.enumerated().map { offset, hash in
                (hash, KnowledgeSidecar.SceneSummary(
                    contentHash: hash, headingPath: ["\(offset + 1)장"],
                    summary: "\(offset + 1)장 요약이다."))
            })
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: summaries.mapValues(\.summary),
            events: [
                hashes[0]: [원인], hashes[1]: [무관], hashes[2]: [결과]
            ],
            sceneSummaries: summaries,
            eventGraph: graph, characters: [남편])
        // 점수 직접 비교 — 원인 씬(멀어도 인과 선행)이 무관한 최근 씬을 이긴다.
        let scores = snapshot.sceneSalienceScores(
            at: outline.scenes[2].utf16Range.lowerBound,
            candidates: Array(outline.scenes.prefix(2)))
        XCTAssertGreaterThan(
            scores[hashes[0]] ?? 0, scores[hashes[1]] ?? 0,
            "원인 씬이 살라이언스에서 이겨야 한다")
        // 조립 경로에서도 같은 순위가 반영된다 — 인과 선행 씬 요약이 실린다.
        let picked = ContextAssembler.knowledgeText(
            snapshot, before: outline.scenes[2].utf16Range.lowerBound)
        XCTAssertTrue(picked.contains("앞선 장면"), picked)
    }
}
