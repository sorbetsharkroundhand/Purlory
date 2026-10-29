@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// Narrative Graph (v5) — 구간·흐름·정본 사건·인과·시간 부분 순서·대화 기록·
/// 인물 감지 강화의 결정적 로직 검증. 요구사항 §35의 End-to-End Case 1–25를
/// 데이터 모델·파서 수준에서 다룬다 (LLM 호출 없음).
final class NarrativeGraphTests: XCTestCase {

    // MARK: - 공용 픽스처

    private let 남편 = CharacterCard(name: "남편")
    private let 아내 = CharacterCard(name: "아내")
    private let 형사 = CharacterCard(name: "형사")

    /// 씬 4개: 1·3·4장 = 현재, 2장 = 회상(오버라이드로 지정).
    private var body4: String {
        """
        # 1장
        남편은 아침을 먹었다. 아내가 커피를 내렸다. 형사가 문을 두드렸다.

        # 2장
        남편이 어린 시절을 떠올렸다. 그날의 여름은 길고 뜨거웠다. 남편은 우물가에서 놀았다.

        # 3장
        형사는 수첩을 꺼냈다. "몇 가지 여쭙겠습니다." 아내는 고개를 끄덕였다.

        # 4장
        진실이 드러났다. 남편은 고개를 떨궜다.
        """
    }

    private func snapshot4(
        events: [String: [StoryEvent]] = [:],
        insights: [String: SceneInsights] = [:],
        segments: [String: SceneSegmentation] = [:],
        eventGraph: EventGraphAnalysis? = nil,
        plotThreads: PlotThreadAnalysis? = nil,
        recorded: [RecordedConversation] = [],
        overrides: [NarrativeOverride] = []
    ) -> KnowledgeSnapshot {
        let outline = DocumentOutline.parse(body4)
        // 2장을 회상 브랜치로.
        let flashbackOverride = NarrativeOverride(
            kind: .sceneType, key: outline.scenes[1].contentHash, value: "회상")
        return KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            events: events, insights: insights,
            segments: segments, eventGraph: eventGraph,
            plotThreadAnalysis: plotThreads,
            recordedConversations: recorded,
            characters: [남편, 아내, 형사],
            overrides: NarrativeOverrides([flashbackOverride] + overrides))
    }

    // MARK: - Case 1: Main → 긴 회상 → Main 복귀 (구간 파서)

    func test_case1_회상_시작과_복귀_추적() {
        let scene = "그는 창가에 앉았다. 남편이 어린 시절을 떠올렸다. 여름은 뜨거웠다. 다시 방 안이었다. 커피가 식어 있었다."
        let output = """
            구간: 층=회상 | 시작="남편이 어린 시절을 떠올렸다" | 끝="다시 방 안이었다" | 복귀=확인 | 깊이=1 | 인물=남편 | 출처=기억
            """
        let segments = SegmentParser.parse(output, sceneHash: "h", sceneText: scene)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].layer, .flashback)
        XCTAssertEqual(segments[0].returnState, .found)
        XCTAssertEqual(segments[0].subjectCharacter, "남편")
        XCTAssertEqual(segments[0].source, .memory)
        // 시작 위치가 실제 원문 위치와 일치.
        let expected = (scene as NSString).range(of: "남편이 어린 시절을 떠올렸다").location
        XCTAssertEqual(segments[0].localStart, expected)
        // 끝 인용 뒤에서 구간이 닫힌다 — 씬 끝까지 확장되지 않는다.
        XCTAssertLessThan(segments[0].localEnd, (scene as NSString).length)
    }

    func test_case1_복귀못찾으면_불확실_유지() {
        let scene = "남편이 어린 시절을 떠올렸다. 여름은 뜨거웠다."
        let output = """
            구간: 층=회상 | 시작="남편이 어린 시절을 떠올렸다" | 복귀=불확실
            """
        let segments = SegmentParser.parse(output, sceneHash: "h", sceneText: scene)
        XCTAssertEqual(segments.count, 1)
        // 임의로 "확정"하지 않는다 (요구사항 §9).
        XCTAssertEqual(segments[0].returnState, .uncertain)
        XCTAssertNil(segments[0].endQuote)
        XCTAssertLessThan(segments[0].confidence, 0.8)
    }

    func test_환각_시작인용은_구간째_버린다() {
        let scene = "남편은 아침을 먹었다."
        let output = """
            구간: 층=회상 | 시작="원문에 없는 문장이다" | 복귀=확인
            """
        XCTAssertTrue(SegmentParser.parse(output, sceneHash: "h", sceneText: scene).isEmpty)
    }

    func test_과거형만으로는_회상이_아니다_현재층_거부() {
        // 층=현재·언급은 구간을 만들지 않는다 (요구사항 §7).
        let scene = "남편은 아침을 먹었다. 옛날 일이 언급되었다."
        let output = """
            구간: 층=현재 | 시작="남편은 아침을 먹었다"
            구간: 층=언급 | 시작="옛날 일이 언급되었다"
            """
        XCTAssertTrue(SegmentParser.parse(output, sceneHash: "h", sceneText: scene).isEmpty)
    }

    // MARK: - Case 2: 회상 속 회상 (중첩 + 복귀 계층)

    func test_case2_중첩회상_부모와_복귀대상() {
        let scene = "남편이 어린 시절을 떠올렸다. 여름의 우물가. 그때 아버지의 어린 시절 이야기가 겹쳤다. 아버지는 전쟁통에 자랐다. 다시 우물가의 여름이었다. 다시 방 안이었다."
        let output = """
            구간: 층=회상 | 시작="남편이 어린 시절을 떠올렸다" | 끝="다시 방 안이었다" | 복귀=확인 | 깊이=1 | 인물=남편
            구간: 층=회상 | 시작="그때 아버지의 어린 시절 이야기가 겹쳤다" | 끝="다시 우물가의 여름이었다" | 복귀=확인 | 깊이=2 | 인물=아버지
            """
        let segments = SegmentParser.parse(output, sceneHash: "h", sceneText: scene)
        XCTAssertEqual(segments.count, 2)
        let outer = segments.first { $0.depth == 1 }!
        let inner = segments.first { $0.depth == 2 }!
        // 중첩 계층 — 안쪽 회상의 부모·복귀 대상이 바깥 회상이다.
        XCTAssertEqual(inner.parentID, outer.persistentID)
        XCTAssertEqual(inner.returnTargetID, outer.persistentID)
        // segment(at:)는 겹치는 위치에서 가장 깊은 구간을 돌려준다.
        let outline = DocumentOutline.parse("# 1장\n\(scene)")
        let hash = outline.scenes[0].contentHash
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            segments: [hash: SceneSegmentation(segments: segments)])
        let innerAbsolute = outline.scenes[0].utf16Range.lowerBound + inner.localStart + 1
        XCTAssertEqual(snapshot.segment(at: innerAbsolute)?.depth, 2)
    }

    // MARK: - Case 3·4: 인물 흐름의 합류와 분화 (공유 사건)

    func test_case3_case4_흐름_합류와_분화() {
        let outline = DocumentOutline.parse(body4)
        let h1 = outline.scenes[0].contentHash
        let h3 = outline.scenes[2].contentHash
        let h4 = outline.scenes[3].contentHash
        let 남편사건 = StoryEvent(sceneHash: h1, participants: [남편.id], summary: "남편의 아침", importance: 3)
        let 공동사건 = StoryEvent(sceneHash: h3, participants: [남편.id, 아내.id], summary: "부부의 대면", importance: 5)
        let 아내사건 = StoryEvent(sceneHash: h4, participants: [아내.id], summary: "아내의 결심", importance: 4)
        let 남편사건2 = StoryEvent(sceneHash: h4, participants: [남편.id], summary: "남편의 자백", importance: 5)
        let snapshot = snapshot4(events: [
            h1: [남편사건], h3: [공동사건], h4: [아내사건, 남편사건2],
        ])
        let husbandFlow = snapshot.flows.first { $0.characterID == 남편.id }!
        let wifeFlow = snapshot.flows.first { $0.characterID == 아내.id }!
        // 합류 — 두 흐름이 같은 정본 사건을 공유한다 (복제 없음).
        let shared = NarrativeFlow.sharedEvents(husbandFlow, wifeFlow)
        XCTAssertEqual(shared, [공동사건.stableKey])
        // 분화 — 공동 사건 이후 각자의 사건으로 갈라진다.
        XCTAssertTrue(husbandFlow.eventKeys.contains(남편사건2.stableKey))
        XCTAssertFalse(wifeFlow.eventKeys.contains(남편사건2.stableKey))
        XCTAssertTrue(wifeFlow.eventKeys.contains(아내사건.stableKey))
        // Main은 모든 정본 사건을 담는 중심 흐름이다 (요구사항 §2).
        let main = snapshot.flows.first { $0.kind == .main }!
        XCTAssertEqual(main.eventKeys.count, 4)
    }

    // MARK: - Case 5·9: 같은 사건의 다른 기억 (관점·신뢰)

    func test_case5_case9_정본사건과_모순되는_관점() {
        let outline = DocumentOutline.parse(body4)
        let h1 = outline.scenes[0].contentHash
        let h2 = outline.scenes[1].contentHash  // 회상 씬
        let 원사건 = StoryEvent(sceneHash: h1, participants: [남편.id, 아내.id], summary: "두 사람의 싸움", importance: 4)
        let 회상사건 = StoryEvent(sceneHash: h2, participants: [남편.id], summary: "아내가 먼저 떠났다", importance: 4)
        let graph = EventGraphAnalysis(
            identities: [
                EventIdentity(
                    canonicalKey: 원사건.stableKey,
                    memberKeys: [원사건.stableKey, 회상사건.stableKey])
            ],
            memoHash: "m")
        let segments = SceneSegmentation(segments: [
            NarrativeSegment(
                sceneHash: h2, localStart: 0, localEnd: 50,
                startQuote: "남편이 어린 시절을 떠올렸다",
                layer: .flashback, depth: 1, source: .memory,
                reliability: .probable)
        ])
        let snapshot = snapshot4(
            events: [h1: [원사건], h2: [회상사건]],
            segments: [h2: segments],
            eventGraph: graph)
        // 정본 사건은 하나 — 복제되지 않는다.
        XCTAssertEqual(snapshot.canonicalEvents.count, 1)
        let canonical = snapshot.canonicalEvents[0]
        XCTAssertEqual(canonical.perspectives.count, 2)
        // 내용이 갈리는 다중 관점 — 어느 쪽도 확정으로 승격되지 않는다 (§12·§13).
        XCTAssertFalse(canonical.perspectives.contains { $0.reliability == .confirmed })
        // 회상 관점의 출처는 기억이다.
        let memoryView = canonical.perspectives.first { $0.sceneHash == h2 }!
        XCTAssertEqual(memoryView.source, .memory)
        // 멤버 키 → 정본 키 역참조.
        XCTAssertEqual(snapshot.canonicalKeyByMember[회상사건.stableKey], 원사건.stableKey)
    }

    // MARK: - Case 6: 씬 내부의 의미 있는 POV 변경

    func test_case6_구간_POV와_position질의() {
        let outline = DocumentOutline.parse(body4)
        let h3 = outline.scenes[2].contentHash
        let segment = NarrativeSegment(
            sceneHash: h3, localStart: 10, localEnd: 40,
            startQuote: "형사는 수첩을 꺼냈다",
            layer: .renarration, depth: 1, pov: "아내", subjectCharacter: "아내")
        let snapshot = snapshot4(segments: [h3: SceneSegmentation(segments: [segment])])
        let inside = outline.scenes[2].utf16Range.lowerBound + 15
        let position = snapshot.position(at: inside)
        XCTAssertEqual(position.layer, .renarration)
        XCTAssertEqual(position.pov, "아내")
        XCTAssertEqual(position.subjectCharacter, "아내")
        // 구간 밖(같은 씬 앞머리)은 바탕 서사다.
        let before = outline.scenes[2].utf16Range.lowerBound + 2
        XCTAssertEqual(snapshot.position(at: before).layer, .present)
    }

    // MARK: - Case 7: 과거 사건 → 현재 사건 인과

    func test_case7_인과_파싱과_질의() {
        let outline = DocumentOutline.parse(body4)
        let h2 = outline.scenes[1].contentHash
        let h4 = outline.scenes[3].contentHash
        let 과거 = StoryEvent(sceneHash: h2, participants: [남편.id], summary: "어린 시절의 상처", importance: 4)
        let 현재 = StoryEvent(sceneHash: h4, participants: [남편.id], summary: "남편의 자백", importance: 5)
        // 파서 — 번호 참조.
        let parsed = EventGraphParser.parse(
            "인과: 1 -> 2 | 종류: 원인 | 이유: 상처가 동기가 됐다",
            keys: [과거.stableKey, 현재.stableKey])
        XCTAssertEqual(parsed.causalLinks.count, 1)
        XCTAssertEqual(parsed.causalLinks[0].kind, .causes)
        let snapshot = snapshot4(
            events: [h2: [과거], h4: [현재]],
            eventGraph: EventGraphAnalysis(causalLinks: parsed.causalLinks, memoHash: "m"))
        XCTAssertEqual(snapshot.causes(of: 현재.stableKey).first?.fromKey, 과거.stableKey)
        XCTAssertEqual(snapshot.effects(of: 과거.stableKey).first?.toKey, 현재.stableKey)
    }

    func test_인과_사용자_삭제와_추가() {
        let outline = DocumentOutline.parse(body4)
        let h1 = outline.scenes[0].contentHash
        let a = StoryEvent(sceneHash: h1, participants: [], summary: "사건A", importance: 3)
        let b = StoryEvent(sceneHash: h1, participants: [], summary: "사건B", importance: 3)
        let aiLink = CausalLink(fromKey: a.stableKey, toKey: b.stableKey, kind: .causes, reason: "")
        // AI 후보를 사용자가 삭제.
        let deleted = snapshot4(
            events: [h1: [a, b]],
            eventGraph: EventGraphAnalysis(causalLinks: [aiLink], memoHash: "m"),
            overrides: [
                NarrativeOverride(
                    kind: .causalLink,
                    key: "원인|\(a.stableKey)|\(b.stableKey)", value: "삭제")
            ])
        XCTAssertTrue(deleted.causalLinks.isEmpty)
        // 사용자가 직접 추가.
        let added = snapshot4(
            events: [h1: [a, b]],
            overrides: [
                NarrativeOverride(
                    kind: .causalLink,
                    key: "폭로|\(b.stableKey)|\(a.stableKey)", value: "추가")
            ])
        XCTAssertEqual(added.causalLinks.count, 1)
        XCTAssertEqual(added.causalLinks[0].kind, .reveals)
    }

    // MARK: - Case 8·25: Reader / Character Knowledge 분리와 누출 차단

    func test_case8_독자는_알고_형사는_모른다() {
        let outline = DocumentOutline.parse(body4)
        let h2 = outline.scenes[1].contentHash  // 회상 — 독자에게 공개
        let insights: [String: SceneInsights] = [
            h2: SceneInsights(knowledge: [
                KnowledgeDelta(
                    characterID: 남편.id, stance: .hides, fact: "남편이 범인이다",
                    sceneHash: h2)
            ])
        ]
        let snapshot = snapshot4(insights: insights)
        let afterScene2 = outline.scenes[2].utf16Range.lowerBound
        // 독자: 회상으로 공개된 사실을 안다.
        XCTAssertEqual(snapshot.readerKnowledge(before: afterScene2).count, 1)
        // 범인(남편): 자기 비밀을 안다(숨김).
        XCTAssertEqual(snapshot.knowledge(of: 남편.id, before: afterScene2).count, 1)
        // 형사: 모른다 — 회상 공개는 인물의 앎이 아니다 (요구사항 §14).
        XCTAssertTrue(snapshot.knowledge(of: 형사.id, before: afterScene2).isEmpty)
    }

    func test_case25_회상집필중_미래앎_누출차단() {
        let outline = DocumentOutline.parse(body4)
        let h2 = outline.scenes[1].contentHash  // 회상 (시간상 과거)
        let h3 = outline.scenes[2].contentHash  // 현재 (시간상 미래)
        let insights: [String: SceneInsights] = [
            h3: SceneInsights(knowledge: [
                KnowledgeDelta(
                    characterID: 남편.id, stance: .knows, fact: "형사가 눈치챘다",
                    sceneHash: h3)
            ])
        ]
        let segments = SceneSegmentation(segments: [
            NarrativeSegment(
                sceneHash: h2, localStart: 0, localEnd: 200,
                startQuote: "남편이 어린 시절을 떠올렸다",
                layer: .flashback, depth: 1, subjectCharacter: "남편")
        ])
        let snapshot = snapshot4(insights: insights, segments: [h2: segments])
        let insideFlashback = outline.scenes[1].utf16Range.lowerBound + 5
        // 담화 기준으로는 3장이 "이미 쓰인" 텍스트지만, 시간 기준으로는 미래다.
        let chronoKnown = snapshot.knowledgeChrono(
            of: 남편.id, atSceneContaining: insideFlashback)
        XCTAssertTrue(chronoKnown.isEmpty, "회상 시점의 남편은 미래의 앎이 없어야 한다")
        // 조립 경로에서도 같은 차단 — 3장 요약이 회상 집필 컨텍스트에 안 실린다.
        let sceneSummaries: [String: KnowledgeSidecar.SceneSummary] = [
            h3: .init(contentHash: h3, headingPath: ["3장"], summary: "형사의 심문이 시작됐다.")
        ]
        let assembled = KnowledgeSnapshot(
            entryID: UUID(), outline: outline,
            summariesByHash: [h3: "형사의 심문이 시작됐다."],
            sceneSummaries: sceneSummaries,
            insights: insights, segments: [h2: segments],
            characters: [남편, 아내, 형사],
            overrides: NarrativeOverrides([
                NarrativeOverride(kind: .sceneType, key: h2, value: "회상")
            ]))
        // 커서를 회상 씬 안에 — 3장은 아직 창 밖(미래)이라고 가정하는 대신,
        // 담화상 이전이지만 시간상 미래인 상황을 만들기 위해 4장 커서로 검사:
        // 여기서는 조립 함수를 직접 호출한다.
        var report: [ContextReport.Item] = []
        let position = assembled.position(at: insideFlashback)
        XCTAssertEqual(position.chrono, .before)
        let block = ContextAssembler.knowledgeText(
            assembled, before: outline.scenes[3].utf16Range.lowerBound,
            position: position, controls: .init(nil), report: &report)
        XCTAssertFalse(block.contains("형사의 심문"), "시간상 미래 씬 요약이 회상 컨텍스트에 새면 안 된다")
    }

    // MARK: - Case 10: 사용자 경계·브랜치 수정

    func test_case10_구간_층수정과_경계수정() {
        let sceneBody = "남편이 어린 시절을 떠올렸다. 여름은 뜨거웠다. 다시 방 안이었다. 커피가 식었다."
        let body = "# 1장\n\(sceneBody)"
        let outline = DocumentOutline.parse(body)
        let hash = outline.scenes[0].contentHash
        let segment = NarrativeSegment(
            sceneHash: hash, localStart: 0, localEnd: 20,
            startQuote: "남편이 어린 시절을 떠올렸다",
            layer: .flashback, depth: 1)
        // ① 층 수정 — "회상이 아님" (현재로).
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            segments: [hash: SceneSegmentation(segments: [segment])],
            overrides: NarrativeOverrides([
                NarrativeOverride(
                    kind: .segmentLayer, key: segment.persistentID, value: "현재")
            ]))
        XCTAssertEqual(snapshot.segmentsByScene[hash]?.first?.layer, .present)
        // 현재 층은 position에서 시간 이동으로 취급되지 않는다.
        let inside = outline.scenes[0].utf16Range.lowerBound + 3
        XCTAssertEqual(snapshot.position(at: inside).layer, .present)

        // ② 경계 수정 — 끝 인용을 사용자가 지정하면 범위·복귀가 갱신된다.
        let bounded = SegmentParser.applyingBoundaryOverrides(
            [hash: SceneSegmentation(segments: [segment])],
            overrides: NarrativeOverrides([
                NarrativeOverride(
                    kind: .segmentEnd, key: segment.persistentID, value: "다시 방 안이었다")
            ]),
            outline: outline, body: body)
        let updated = bounded[hash]!.segments[0]
        XCTAssertEqual(updated.returnState, .found)
        XCTAssertEqual(updated.endQuote, "다시 방 안이었다")
        XCTAssertEqual(updated.persistentID, segment.persistentID)  // ID 유지 (§27)
        // ③ 원문에 없는 경계는 무시 — 기존 경계 유지 (오적용보다 stale).
        let unchanged = SegmentParser.applyingBoundaryOverrides(
            [hash: SceneSegmentation(segments: [segment])],
            overrides: NarrativeOverrides([
                NarrativeOverride(
                    kind: .segmentEnd, key: segment.persistentID, value: "원문에 없는 문장")
            ]),
            outline: outline, body: body)
        XCTAssertEqual(unchanged[hash]!.segments[0].returnState, .uncertain)
    }

    // MARK: - Case 11·12: 인물 감지 정밀도

    func test_case11_실제_이름은_감지된다() {
        let body = """
            # 1장
            재형이 문을 열었다. "왔어?" 재형이 물었다. 민수는 재형에게 손을 흔들었다.

            # 2장
            민수가 말했다. "오랜만이야." 재형은 민수에게 커피를 건넸다.

            # 3장
            재형이 웃었다. 민수가 대답했다. 재형은 민수를 바라보았다.

            # 4장
            "재형아, 이리 와." 민수가 불렀다. 재형이 달려갔다. 민수는 재형에게 책을 주었다.

            # 5장
            재형이 말했다. 민수가 고개를 끄덕였다. 재형은 민수와 함께 걸었다.
            """
        let outline = DocumentOutline.parse(body)
        let candidates = CharacterDetector.detect(
            body: body, outline: outline, known: [], rejected: [])
        let names = candidates.map(\.name)
        XCTAssertTrue(names.contains("재형"), "감지된 이름: \(names)")
        XCTAssertTrue(names.contains("민수"), "감지된 이름: \(names)")
        // 구조 신호가 겹겹인 이름은 HIGH — 자동 등록 대상 (요구사항 §16).
        XCTAssertEqual(candidates.first { $0.name == "재형" }?.confidence, .high)
    }

    func test_case12_일반어는_등록되지_않는다() {
        let body = """
            # 1장
            그러나 그는 버리고 떠났다. 그러나 마음은 남았다. 그러나 시간이 흘렀다.

            # 2장
            그러나 밤이 왔다. 그는 버리고 또 버리고 걸었다. 그러나 아침이 왔다.

            # 3장
            그러나 끝은 없었다. 그는 생각을 버리고 잠들었다. 그러나 꿈을 꾸었다.
            """
        let outline = DocumentOutline.parse(body)
        let candidates = CharacterDetector.detect(
            body: body, outline: outline, known: [], rejected: [])
        let names = candidates.map(\.name)
        XCTAssertFalse(names.contains("그러나"))
        XCTAssertFalse(names.contains("그"))
        XCTAssertFalse(names.contains("버리고"))
    }

    // MARK: - Case 13: 표기 변형 연결 (Entity Resolution)

    func test_case13_김재형_재형_재형이_한_후보로() {
        let make = { (name: String) in
            CharacterDetector.Candidate(
                name: name, mentions: 6, sceneCount: 3, animacyHits: 2, caseRoleCount: 2,
                confidence: .high)
        }
        let merged = CharacterDetector.mergeAliasForms(
            [make("김재형"), make("재형"), make("재형이")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "김재형")
        XCTAssertEqual(Set(merged[0].aliasForms), Set(["재형", "재형이"]))
        XCTAssertEqual(merged[0].mentions, 18)  // 증거 합산
        // 관련 없는 이름은 묶이지 않는다.
        let separate = CharacterDetector.mergeAliasForms([make("김재형"), make("민수")])
        XCTAssertEqual(separate.count, 2)
    }

    func test_기존인물의_별칭후보는_자동등록되지_않는다() {
        let body = """
            # 1장
            재형이 문을 열었다. 재형이 말했다. 민수는 재형에게 인사했다.

            # 2장
            재형이 웃었다. 재형은 민수에게 커피를 건넸다. "재형아." 민수가 불렀다.

            # 3장
            재형이 대답했다. 재형은 민수와 걸었다. 민수가 재형에게 말했다.
            """
        let outline = DocumentOutline.parse(body)
        // "김재형"이 이미 등록돼 있다 — "재형"은 별칭 후보로 표시돼야 한다.
        let candidates = CharacterDetector.detect(
            body: body, outline: outline, known: ["김재형"], rejected: [])
        let 재형후보 = candidates.first { $0.name == "재형" }
        XCTAssertEqual(재형후보?.aliasOfKnown, "김재형")
        XCTAssertEqual(재형후보?.confidence, .medium)  // 자동 등록 금지
    }

    // MARK: - Case 14·15: 대화 블록 감지

    func test_case14_연속발화를_하나의_블록으로() {
        let text = """
            민수가 방에 들어왔다.

            "오늘 어디 가?"
            민수가 물었다.
            "잠깐 나갔다 올게."
            재형은 대답하지 않았다.
            "언제 와?"
            """
        let ns = text as NSString
        let block = ConversationDetector.blockEnding(at: ns.length, in: ns)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.utteranceCount, 3)
        XCTAssertEqual(block?.firstLine, "오늘 어디 가?")
        XCTAssertEqual(block?.lastLine, "언제 와?")
        // 대화 앞의 서술("민수가 방에 들어왔다")은 블록 밖이다.
        let start = block!.utf16Range.lowerBound
        XCTAssertTrue(ns.substring(from: start).hasPrefix("\"오늘"))
    }

    func test_case15_발화_한개면_제안하지_않는다() {
        let text = "\"안녕.\"\n그는 갔다."
        let ns = text as NSString
        XCTAssertNil(ConversationDetector.blockEnding(at: ns.length, in: ns))
    }

    func test_긴서술이_끼면_대화가_끊긴다() {
        let narration = String(repeating: "긴 서술이다. ", count: 30)
        let text = """
            "먼 옛날 대사."
            \(narration)
            "지금 대사."
            "이어지는 대사."
            """
        let ns = text as NSString
        let block = ConversationDetector.blockEnding(at: ns.length, in: ns)
        XCTAssertEqual(block?.utteranceCount, 2)  // 긴 서술 앞은 다른 대화다
    }

    // MARK: - Case 16·17: 기록 → 인덱스 통합 → 원문 참조

    func test_case16_case17_기록된_대화가_인덱스에_통합된다() {
        let record = RecordedConversation(
            participants: [남편.id, 아내.id],
            utf16Start: 100, utf16End: 180,
            firstLine: "몇 가지 여쭙겠습니다.", lastLine: "몇 가지 여쭙겠습니다.",
            contentHash: "hash1")
        let snapshot = snapshot4(recorded: [record])
        // 자동 감지가 없어도 기록 자체가 대화 항목이 된다.
        let recorded = snapshot.conversations.first { $0.recordedID == record.id }
        XCTAssertNotNil(recorded)
        XCTAssertEqual(Set(recorded!.participants), Set([남편.id, 아내.id]))
        // 인물별 열람 (요구사항 §21) — 원문 점프 질의는 첫 대사.
        XCTAssertTrue(
            snapshot.conversations(involving: 남편.id).contains { $0.recordedID == record.id })
        XCTAssertEqual(recorded?.firstLine, "몇 가지 여쭙겠습니다.")
    }

    func test_기록_재앵커_원문수정후() {
        let body = "서두 문단.\n\n\"몇 가지 여쭙겠습니다.\"\n아내는 끄덕였다.\n\"고맙습니다.\""
        let record = RecordedConversation(
            participants: [], utf16Start: 0, utf16End: 10,  // 낡은 위치
            firstLine: "몇 가지 여쭙겠습니다.", lastLine: "고맙습니다.",
            contentHash: "h")
        let anchored = ConversationDetector.reanchor(record, in: body as NSString)
        XCTAssertNotNil(anchored)
        let ns = body as NSString
        let start = ns.range(of: "\"몇 가지").location
        XCTAssertEqual(anchored?.utf16Start, start)
        XCTAssertTrue(ns.substring(to: anchored!.utf16End).hasSuffix("\"고맙습니다.\""))
        // 첫 대사가 사라졌으면 nil — 엉뚱한 위치로 잇지 않는다.
        XCTAssertNil(ConversationDetector.reanchor(record, in: "전혀 다른 본문" as NSString))
    }

    func test_기록_재앵커_현재범위해시가_맞으면_원본을유지한다() {
        let body = "\"어디 가?\"\n\"금방 다녀올게.\""
        let ns = body as NSString
        let record = RecordedConversation(
            participants: [], utf16Start: 0, utf16End: ns.length,
            firstLine: "어디 가?", lastLine: "금방 다녀올게.",
            contentHash: DocumentOutline.stableHash(body))

        XCTAssertEqual(ConversationDetector.reanchor(record, in: ns), record)
    }

    func test_기록_재앵커_반복대사는_기존위치와_가까운블록을_선택한다() {
        let body = "\"네.\"\n\"먼저 갈게.\"\n\n긴 서술.\n\n\"네.\"\n\"나중에 갈게.\""
        let ns = body as NSString
        let expectedStart = ns.range(of: "\"네.\"", options: .backwards).location
        let record = RecordedConversation(
            participants: [], utf16Start: expectedStart + 2, utf16End: ns.length,
            firstLine: "네.", lastLine: "나중에 갈게.", contentHash: "낡은 해시")

        let anchored = ConversationDetector.reanchor(record, in: ns)

        XCTAssertEqual(anchored?.utf16Start, expectedStart)
        XCTAssertTrue(ns.substring(to: anchored!.utf16End).hasSuffix("\"나중에 갈게.\""))
    }

    func test_기록_재앵커_마지막대사를_찾지못하면_nil이다() {
        let body = "서두\n\"어디 가?\"\n대화가 잘렸다."
        let record = RecordedConversation(
            participants: [], utf16Start: 0, utf16End: 10,
            firstLine: "어디 가?", lastLine: "금방 다녀올게.", contentHash: "낡은 해시")

        XCTAssertNil(ConversationDetector.reanchor(record, in: body as NSString))
    }

    func test_기록_재앵커_서로다른대화블록의_첫끝을_잇지않는다() {
        let body = """
            \"네.\"
            이 블록에는 끝 대사가 없다.

            장면이 완전히 바뀌었다. 인물도 장소도 다르다.

            \"처음 뵙겠습니다.\"
            \"나중에 갈게.\"
            """
        let ns = body as NSString
        let nearFirst = ns.range(of: "\"네.\"").location
        let record = RecordedConversation(
            participants: [], utf16Start: nearFirst, utf16End: nearFirst + 20,
            firstLine: "네.", lastLine: "나중에 갈게.", contentHash: "낡은 해시")

        XCTAssertNil(ConversationDetector.reanchor(record, in: ns))
    }

    func test_기록_재앵커_첫대사가60자를넘어도_저장접두로찾는다() {
        let first = String(repeating: "아주긴대사", count: 16)
        let conversation = "\"\(first)\"\n\"마지막 대사.\""
        let body = "앞에 새로 삽입된 문단.\n\n" + conversation
        let ns = body as NSString
        let expectedStart = ns.range(of: "\"\(first)\"").location
        let record = RecordedConversation(
            participants: [], utf16Start: 0,
            utf16End: (conversation as NSString).length,
            firstLine: String(first.prefix(60)), lastLine: "마지막 대사.",
            contentHash: "삽입 전 해시")

        let anchored = ConversationDetector.reanchor(record, in: ns)

        XCTAssertEqual(anchored?.utf16Start, expectedStart)
        XCTAssertEqual(anchored?.utf16End, ns.length)
    }

    // MARK: - Case 18–23: 통합 서사 화면 — 흐름 Projection 행 모델

    func test_case18_case20_흐름행_정본사건과_관점참조() {
        let outline = DocumentOutline.parse(body4)
        let h1 = outline.scenes[0].contentHash
        let h2 = outline.scenes[1].contentHash  // 회상
        let e1 = StoryEvent(sceneHash: h1, participants: [남편.id], summary: "아침", importance: 3)
        let e2 = StoryEvent(sceneHash: h2, participants: [남편.id], summary: "우물가의 기억", importance: 4)
        // e1·e2를 같은 사건으로 판정 (2장의 재서술).
        let graph = EventGraphAnalysis(
            identities: [
                EventIdentity(canonicalKey: e1.stableKey, memberKeys: [e1.stableKey, e2.stableKey])
            ])
        let snapshot = snapshot4(events: [h1: [e1], h2: [e2]], eventGraph: graph)
        let rows = GraphRow.flowRows(from: snapshot, expandedMinors: [])
        // 정본 사건 행은 첫 등장 씬(1장)에 한 번만 — 사건 복제 금지 (요구사항 §3·§12).
        let eventKeys = rows.compactMap(\.eventKey)
        XCTAssertEqual(eventKeys.filter { $0 == e1.stableKey }.count, 1)
        // 2장(회상)에는 관점 참조 행이 정본을 가리킨다.
        let refKeys = rows.compactMap { row -> String? in
            if case .perspectiveRef(_, let key, _) = row { return key }
            return nil
        }
        XCTAssertEqual(refKeys, [e1.stableKey])
    }

    func test_관점_구간_역추적() {
        // EventPerspective.segmentID → 구간, storyEvent(forMember:) → 원본 사건.
        // 정본 사건에서 Scene/Segment/StoryEvent로의 역추적 통로 (통합 상세 패널).
        let outline = DocumentOutline.parse(body4)
        let h2 = outline.scenes[1].contentHash
        let segment = NarrativeSegment(
            sceneHash: h2, localStart: 0, localEnd: 30,
            startQuote: "남편이 어린 시절을 떠올렸다", layer: .flashback, depth: 1)
        let e2 = StoryEvent(
            sceneHash: h2, participants: [남편.id], summary: "우물가의 기억", importance: 4)
        let snapshot = snapshot4(
            events: [h2: [e2]],
            segments: [h2: SceneSegmentation(segments: [segment])])
        let canonical = snapshot.canonicalEvent(for: e2.stableKey)
        XCTAssertEqual(canonical?.perspectives.first?.segmentID, segment.persistentID)
        XCTAssertEqual(snapshot.segment(withID: segment.persistentID)?.layer, .flashback)
        XCTAssertEqual(snapshot.storyEvent(forMember: e2.stableKey)?.summary, "우물가의 기억")
    }

    func test_case21_case22_색_안정성과_행_결정성() {
        let flow1 = NarrativeFlow(id: "flow-chr-ABC", kind: .character, name: "남편")
        let flow2 = NarrativeFlow(id: "flow-chr-ABC", kind: .character, name: "남편(개명)")
        // 색 시드는 persistent ID에서만 나온다 — 이름·재분석과 무관 (요구사항 §24).
        XCTAssertEqual(flow1.colorSeed, flow2.colorSeed)
        XCTAssertNotEqual(
            NarrativeFlow(id: "flow-chr-XYZ", kind: .character, name: "아내").colorSeed,
            flow1.colorSeed)
        // 행 모델 재계산 안정성 — 같은 스냅샷이면 같은 행 (요구사항 §25).
        let outline = DocumentOutline.parse(body4)
        let h1 = outline.scenes[0].contentHash
        let e1 = StoryEvent(sceneHash: h1, participants: [남편.id, 아내.id], summary: "사건", importance: 3)
        let e2 = StoryEvent(sceneHash: h1, participants: [남편.id, 아내.id], summary: "사건2", importance: 3)
        let snapshot = snapshot4(events: [h1: [e1, e2]])
        let a = GraphRow.flowRows(from: snapshot, expandedMinors: [])
        let b = GraphRow.flowRows(from: snapshot, expandedMinors: [])
        XCTAssertEqual(a.map(\.id), b.map(\.id))
    }

    // MARK: - Case 24는 UI 통로(requestSearchJump) — 재앵커 사다리를 검증

    func test_case24_재앵커_사다리() {
        let body = "그는 오래된 우물가에서 어린 시절을 보냈다. 여름은 길었다."
        // exact.
        XCTAssertEqual(
            SourceAnchor.resilientQuery(for: "우물가에서 어린 시절", in: body),
            "우물가에서 어린 시절")
        // 소폭 수정 — 어절 지문으로 그 줄을 되찾는다.
        let edited = "그는 낡은 우물가 근처에서 어린 시절을 보냈다. 여름은 길었다."
        let recovered = SourceAnchor.resilientQuery(
            for: "오래된 우물가에서 어린 시절을 보냈다", in: edited)
        XCTAssertNotNil(recovered)
        XCTAssertTrue(edited.contains(recovered!))
        // 완전히 사라짐 — nil (stale이 오적용보다 낫다).
        XCTAssertNil(
            SourceAnchor.resilientQuery(for: "우물가에서 어린 시절을 보냈다", in: "무관한 본문이다."))
    }

    // MARK: - 시간 부분 순서 (요구사항 §29)

    func test_부분순서_위상정렬과_모순감지() {
        let items = ["a", "b", "c", "d"]
        // c가 a보다 과거 — 담화 순서를 거슬러 앞으로 온다.
        let resolved = ChronoOrder.resolve(
            items: items,
            edges: [ChronoEdge(aKey: "c", bKey: "a", relation: .before)])
        XCTAssertLessThan(
            resolved.ordered.firstIndex(of: "c")!, resolved.ordered.firstIndex(of: "a")!)
        XCTAssertTrue(resolved.conflicts.isEmpty)
        // 모순 (a<b, b<a) — 사이클 간선이 Conflict로 보고되고 정렬은 무너지지 않는다.
        let conflicted = ChronoOrder.resolve(
            items: items,
            edges: [
                ChronoEdge(aKey: "a", bKey: "b", relation: .before),
                ChronoEdge(aKey: "b", bKey: "a", relation: .before),
            ])
        XCTAssertEqual(conflicted.conflicts.count, 1)
        XCTAssertEqual(conflicted.ordered.count, 4)
        // unknown·approximate는 제약이 아니다 — 담화 순서 유지.
        let loose = ChronoOrder.resolve(
            items: items,
            edges: [ChronoEdge(aKey: "d", bKey: "a", relation: .approximate)])
        XCTAssertEqual(loose.ordered, items)
    }

    func test_회상브랜치_사건이_시간순서_앞으로() {
        let outline = DocumentOutline.parse(body4)
        let h2 = outline.scenes[1].contentHash  // 회상
        let h3 = outline.scenes[2].contentHash
        let 과거 = StoryEvent(sceneHash: h2, participants: [], summary: "과거의 상처", importance: 3)
        let 현재 = StoryEvent(sceneHash: h3, participants: [], summary: "현재의 심문", importance: 3)
        let snapshot = snapshot4(events: [h2: [과거], h3: [현재]])
        // 층 파생 간선 — 회상 사건이 시간순으로 앞이다.
        XCTAssertLessThan(
            snapshot.chronoRank(of: 과거.stableKey)!,
            snapshot.chronoRank(of: 현재.stableKey)!)
    }

    // MARK: - Pin / Exclude (요구사항 §31)

    func test_컨텍스트_제외는_조립에서_빠진다() {
        let outline = DocumentOutline.parse(body4)
        let h1 = outline.scenes[0].contentHash
        let sceneSummaries: [String: KnowledgeSidecar.SceneSummary] = [
            h1: .init(contentHash: h1, headingPath: ["1장"], summary: "아침의 방문.")
        ]
        let base = KnowledgeSnapshot(
            entryID: UUID(), outline: outline,
            summariesByHash: [h1: "아침의 방문."],
            sceneSummaries: sceneSummaries,
            characters: [남편])
        var report: [ContextReport.Item] = []
        let cursor = outline.scenes[2].utf16Range.lowerBound
        let with = ContextAssembler.knowledgeText(base, before: cursor, report: &report)
        XCTAssertTrue(with.contains("아침의 방문"))
        // 제외 오버라이드 적용.
        let excluded = KnowledgeSnapshot(
            entryID: UUID(), outline: outline,
            summariesByHash: [h1: "아침의 방문."],
            sceneSummaries: sceneSummaries,
            characters: [남편],
            overrides: NarrativeOverrides([
                NarrativeOverride(kind: .contextExclude, key: "scene|\(h1)", value: "제외")
            ]))
        var report2: [ContextReport.Item] = []
        let without = ContextAssembler.knowledgeText(
            excluded, before: cursor,
            controls: .init(excluded), report: &report2)
        XCTAssertFalse(without.contains("아침의 방문"))
    }

    // MARK: - 사이드카 v5 왕복

    func test_사이드카_v5_왕복() throws {
        var sidecar = KnowledgeSidecar(entryID: UUID())
        let fixed = Date(timeIntervalSince1970: 1_750_000_000)
        sidecar.segments["h1"] = SceneSegmentation(
            segments: [
                NarrativeSegment(
                    sceneHash: "h1", localStart: 0, localEnd: 10,
                    startQuote: "그날의 여름", layer: .flashback, depth: 1)
            ],
            updatedAt: fixed)
        sidecar.eventGraph = EventGraphAnalysis(
            causalLinks: [CausalLink(fromKey: "a", toKey: "b", kind: .causes, reason: "이유")],
            identities: [EventIdentity(canonicalKey: "a", memberKeys: ["a", "c"])],
            chronoEdges: [ChronoEdge(aKey: "c", bKey: "a", relation: .before)],
            memoHash: "m", updatedAt: fixed)
        sidecar.plotThreads = PlotThreadAnalysis(
            threads: [
                PlotThread(
                    title: "살인사건의 진실", summary: "남편의 죽음을 파헤친다",
                    memberships: [
                        EventThreadMembership(eventKey: "a", role: .opens),
                        EventThreadMembership(eventKey: "b", role: .advances),
                    ],
                    resolvedAtKey: "b")
            ],
            memoHash: "p", updatedAt: fixed)
        sidecar.conversationMeta["id1"] = ConversationMeta(
            contentHash: "ch", topic: "과거 이야기", tone: "긴장",
            keyStatements: ["몇 가지 여쭙겠습니다"], updatedAt: fixed)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            KnowledgeSidecar.self, from: encoder.encode(sidecar))
        XCTAssertEqual(decoded, sidecar)
        XCTAssertEqual(KnowledgeSidecar.currentSchemaVersion, 8)
    }

    // MARK: - 의미 경계 분할 (요구사항 §32)

    func test_장면구분자에서_세그먼트가_끊긴다() {
        let part1 = String(repeating: "첫 장면의 문장이다. ", count: 30)
        let part2 = String(repeating: "둘째 장면의 문장이다. ", count: 30)
        let body = part1 + "\n\n***\n\n" + part2
        let outline = DocumentOutline.parse(body)
        XCTAssertGreaterThanOrEqual(outline.scenes.count, 2)
        // 구분자가 어느 세그먼트의 끝에 붙어 있다 — 경계가 구분자와 일치한다.
        let text = body as NSString
        let hasBreakBoundary = outline.scenes.contains { scene in
            let content = text.substring(
                with: NSRange(
                    location: scene.utf16Range.lowerBound, length: scene.utf16Range.count))
            return content.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("***")
        }
        XCTAssertTrue(hasBreakBoundary)
    }

    // MARK: - 서사 위치가 조립에 실린다 (요구사항 §30)

    func test_조립_회상구간에서_흐름라인_주입() {
        let outline = DocumentOutline.parse(body4)
        let h2 = outline.scenes[1].contentHash
        let segments = SceneSegmentation(segments: [
            NarrativeSegment(
                sceneHash: h2, localStart: 0, localEnd: 500,
                startQuote: "남편이 어린 시절을 떠올렸다",
                layer: .flashback, depth: 1, subjectCharacter: "남편")
        ])
        let snapshot = snapshot4(segments: [h2: segments])
        let document = DocumentContext(
            title: "시험작", kind: .novel, characters: [남편, 아내, 형사])
        let cursorScene = outline.scenes[1]
        let prefix = "그날의 여름은 "
        let (prompt, report) = ContextAssembler.assembleWithReport(
            prefix: prefix,
            document: document,
            knowledge: snapshot,
            prefixStartUTF16: cursorScene.utf16Range.lowerBound + 5,
            style: .continuation)
        guard case .continuation(let text) = prompt else {
            return XCTFail("continuation이어야 한다")
        }
        XCTAssertTrue(text.contains("지금 흐름:"), "회상 집필 중 서사 위치 라인이 실려야 한다")
        XCTAssertTrue(report.items.contains { $0.kind == .narrative })
    }
}
