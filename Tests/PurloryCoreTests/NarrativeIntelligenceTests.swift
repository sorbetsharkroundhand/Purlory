@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// Narrative Intelligence (v4) — 근거·앎·관계·브랜치·대화 인덱스·
/// 사용자 수정 보호의 결정적 로직 검증. LLM 호출 없는 파서·질의만 다룬다.
final class NarrativeIntelligenceTests: XCTestCase {

    // MARK: - 공용 픽스처

    private let 서연 = CharacterCard(name: "서연")
    private let 민준 = CharacterCard(name: "민준")

    private var nameIndex: [String: UUID] {
        EventParser.nameIndex([서연, 민준])
    }

    /// 헤딩 3개 = 씬 3개 (짧아서 분할 없음).
    private var body3: String {
        """
        # 1장
        서연이 병원 문을 나섰다. 하늘은 맑았고, 그는 오랜만에 웃었다.

        # 2장
        민준이 어린 시절을 떠올렸다. 그때의 여름은 길고 뜨거웠다.

        # 3장
        두 사람은 카페에서 다시 만났다. "오랜만이야." 서연이 말했다.
        """
    }

    // MARK: - 문장 경계 절단 (요구사항 §2)

    func test_문장경계_절단_긴텍스트() {
        let text = "그는 자신을 위조하고 19세기를 봉쇄한다. 감정조차 포즈로 여기며 산다. 이 문장은 상한을 넘어 잘려야 한다."
        let clamped = SentenceClamp.clamp(text, to: 30)
        // 상한 안의 마지막 완결 문장까지 — 중간에서 끊기지 않는다.
        XCTAssertEqual(clamped, "그는 자신을 위조하고 19세기를 봉쇄한다.")
        XCTAssertTrue(clamped.hasSuffix("."))
    }

    func test_문장경계_절단_상한이하는_그대로() {
        XCTAssertEqual(SentenceClamp.clamp("짧은 요약.", to: 120), "짧은 요약.")
    }

    func test_문장경계_절단_종결부호없음_어절경계() {
        let text = "종결부호 없이 길게 이어지는 명사구 나열 그리고 계속되는 말들"
        let clamped = SentenceClamp.clamp(text, to: 20)
        XCTAssertLessThanOrEqual(clamped.count, 21)  // "…" 포함
        XCTAssertFalse(clamped.contains("나열 그리고"))
    }

    // MARK: - 사건 파서: 근거 인용 (요구사항 §3)

    func test_사건_근거인용_원문검증_통과() {
        let scene = "서연이 병원 문을 나섰다. 하늘은 맑았다."
        let output = "서연이 퇴원했다 | 참여: 서연 | 중요도: 4 | 근거: \"병원 문을 나섰다\""
        let events = EventParser.parse(
            output, sceneHash: "h1", nameIndex: nameIndex, sceneText: scene)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].quote, "병원 문을 나섰다")
        XCTAssertEqual(events[0].evidenceKind, .direct)
        XCTAssertEqual(events[0].importance, 4)
    }

    func test_사건_근거인용_환각은_추론으로_강등() {
        let scene = "서연이 병원 문을 나섰다."
        let output = "서연이 퇴원했다 | 참여: 서연 | 근거: \"원문에 없는 지어낸 인용문\""
        let events = EventParser.parse(
            output, sceneHash: "h1", nameIndex: nameIndex, sceneText: scene)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].quote)
        XCTAssertEqual(events[0].evidenceKind, .inferred)
    }

    func test_사건_안정키_요약이_같으면_같다() {
        let a = StoryEvent(sceneHash: "h1", participants: [], summary: "같은 요약", importance: 3)
        let b = StoryEvent(sceneHash: "h2", participants: [], summary: "같은 요약", importance: 5)
        XCTAssertEqual(a.stableKey, b.stableKey)  // 씬이 재해시돼도 키 유지
    }

    func test_사건파서는_같은씬의_동일사건줄을_한번만_보존한다() {
        let output = """
            문이 열린다 | 중요도: 4
            문이 열린다 | 중요도: 4
            서연이 들어온다 | 중요도: 3
            """

        let events = EventParser.parse(
            output, sceneHash: "scene-1", nameIndex: [:])

        XCTAssertEqual(events.map(\.summary), ["문이 열린다", "서연이 들어온다"])
    }

    // MARK: - 심화 파서 (앎·관계)

    func test_심화_앎_파싱과_태도검증() {
        let output = """
            앎: 서연 의심=민준이 약을 바꿨다 | 근거: "지어낸 인용"
            앎: 서연 확신=닫힌 집합 밖 태도는 버려진다
            앎: 유령 의심=미등록 인물은 버려진다
            """
        let insights = InsightParser.parse(
            output, sceneHash: "h1", nameIndex: nameIndex, sceneText: "본문")
        XCTAssertEqual(insights.knowledge.count, 1)
        XCTAssertEqual(insights.knowledge[0].stance, .suspects)
        XCTAssertEqual(insights.knowledge[0].fact, "민준이 약을 바꿨다")
        XCTAssertNil(insights.knowledge[0].quote)  // 환각 인용은 버린다
    }

    func test_심화_관계_방향파싱() {
        let output = "관계: 서연→민준=의심과 경계"
        let insights = InsightParser.parse(output, sceneHash: "h1", nameIndex: nameIndex)
        XCTAssertEqual(insights.relations.count, 1)
        XCTAssertEqual(insights.relations[0].fromID, 서연.id)
        XCTAssertEqual(insights.relations[0].toID, 민준.id)
        XCTAssertEqual(insights.relations[0].value, "의심과 경계")
    }

    // MARK: - 씬 분석 파서 (요구사항 §6)

    func test_씬분석_제목_요약_유형() {
        let output = """
            제목: 아내의 외출과 남편의 불안
            요약: 아내가 외출하고 남편은 방에 남아 불안해한다.
            유형: 회상
            시점: 남편
            장소: 33번지 방
            """
        let analysis = BackgroundIndexer.parseSceneAnalysis(output)
        XCTAssertEqual(analysis?.title, "아내의 외출과 남편의 불안")
        XCTAssertEqual(analysis?.narrativeType, "회상")
        XCTAssertEqual(analysis?.pov, "남편")
        XCTAssertEqual(analysis?.location, "33번지 방")
        XCTAssertTrue(analysis?.summary.hasSuffix("불안해한다.") == true)
    }

    func test_씬분석_요약없으면_nil_산문폴백() {
        XCTAssertNil(BackgroundIndexer.parseSceneAnalysis("제목: 제목만"))
        // 구형 응답(키 없는 요약 한 줄)은 요약으로 받아들인다.
        let legacy = BackgroundIndexer.parseSceneAnalysis("아내가 외출하고 남편은 불안해한다.")
        XCTAssertNotNil(legacy)
        XCTAssertNil(legacy?.title)
    }

    // MARK: - 브랜치 파생 (요구사항 §8)

    func test_브랜치_연속회상만_묶인다() {
        let types: [SceneNarrativeType] = [.present, .flashback, .flashback, .present, .dream]
        let hashes = ["a", "b", "c", "d", "e"]
        let branches = NarrativeBranch.derive(types: types, anchorHashes: hashes)
        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(branches[0].type, .flashback)
        XCTAssertEqual(branches[0].sceneRange, 1..<3)
        XCTAssertEqual(branches[0].chrono, .before)
        XCTAssertEqual(branches[1].type, .dream)
        XCTAssertEqual(branches[1].sceneRange, 4..<5)
    }

    func test_브랜치_이름_시간관계_오버라이드() {
        let branches = NarrativeBranch.derive(
            types: [.present, .flashback], anchorHashes: ["a", "b"],
            nameOverrides: ["b": "유년의 여름"],
            chronoOverrides: ["b": .simultaneous])
        XCTAssertEqual(branches[0].name, "유년의 여름")
        XCTAssertEqual(branches[0].chrono, .simultaneous)
        XCTAssertTrue(branches[0].userEdited)
    }

    // MARK: - 대화 인덱스 (요구사항 §13)

    func test_대화인덱스_간격과_씬경계로_묶는다() {
        let outline = DocumentOutline.parse(body3)
        let utterances = [
            Utterance(speakerID: 서연.id, text: "안녕", utf16Start: 10, listenerID: 민준.id, politeness: .plain),
            Utterance(speakerID: 민준.id, text: "오랜만", utf16Start: 20, listenerID: 서연.id, politeness: .plain),
            // 큰 간격 — 새 대화.
            Utterance(speakerID: 서연.id, text: "잘 지냈어?", utf16Start: 3_000, listenerID: 민준.id, politeness: .plain),
        ]
        let conversations = Conversation.index(
            utterances: utterances, outline: outline, maxGapUTF16: 400)
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations[0].utteranceCount, 2)
        XCTAssertEqual(Set(conversations[0].participants), Set([서연.id, 민준.id]))
        XCTAssertEqual(conversations[0].firstLine, "안녕")
    }

    // MARK: - 스냅샷 질의: 앎 시점 차단 (요구사항 §11)

    func test_앎_시점차단과_태도갱신() {
        let outline = DocumentOutline.parse(body3)
        let scenes = outline.scenes
        XCTAssertEqual(scenes.count, 3)
        let h1 = scenes[0].contentHash
        let h3 = scenes[2].contentHash
        let insights: [String: SceneInsights] = [
            h1: SceneInsights(knowledge: [
                KnowledgeDelta(characterID: 서연.id, stance: .suspects, fact: "약이 바뀌었다", sceneHash: h1)
            ]),
            h3: SceneInsights(knowledge: [
                KnowledgeDelta(characterID: 서연.id, stance: .knows, fact: "약이 바뀌었다", sceneHash: h3)
            ]),
        ]
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:], insights: insights)

        // 2장 커서: 1장 앎만 (의심).
        let mid = snapshot.knowledge(of: 서연.id, before: scenes[1].utf16Range.upperBound)
        XCTAssertEqual(mid.count, 1)
        XCTAssertEqual(mid[0].stance, .suspects)
        // 문서 끝: 같은 사실의 나중 태도(안다)가 이긴다.
        let end = snapshot.knowledge(of: 서연.id, before: .max)
        XCTAssertEqual(end.count, 1)
        XCTAssertEqual(end[0].stance, .knows)
        // 1장 시작 전: 아무것도 모른다.
        XCTAssertTrue(snapshot.knowledge(of: 서연.id, before: 0).isEmpty)
    }

    func test_관계_이력과_현재값() {
        let outline = DocumentOutline.parse(body3)
        let scenes = outline.scenes
        let insights: [String: SceneInsights] = [
            scenes[0].contentHash: SceneInsights(relations: [
                RelationDelta(fromID: 민준.id, toID: 서연.id, value: "사랑", sceneHash: scenes[0].contentHash)
            ]),
            scenes[2].contentHash: SceneInsights(relations: [
                RelationDelta(fromID: 민준.id, toID: 서연.id, value: "의심", sceneHash: scenes[2].contentHash)
            ]),
        ]
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:], insights: insights)
        XCTAssertEqual(
            snapshot.relation(from: 민준.id, to: 서연.id, before: .max)?.value, "의심")
        XCTAssertEqual(
            snapshot.relation(
                from: 민준.id, to: 서연.id,
                before: scenes[1].utf16Range.upperBound)?.value, "사랑")
        XCTAssertEqual(snapshot.relationHistory(from: 민준.id, to: 서연.id).count, 2)
    }

    // MARK: - 사용자 수정 적용 (요구사항 §9)

    func test_씬제목_오버라이드가_스냅샷에_적용된다() {
        let outline = DocumentOutline.parse(body3)
        let hash = outline.scenes[0].contentHash
        let sidecarSummaries: [String: KnowledgeSidecar.SceneSummary] = [
            hash: .init(
                contentHash: hash, headingPath: ["1장"], summary: "요약.",
                title: "AI가 지은 제목", narrativeType: "현재")
        ]
        let overrides = NarrativeOverrides([
            NarrativeOverride(kind: .sceneTitle, key: hash, value: "내가 고친 제목")
        ])
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            sceneSummaries: sidecarSummaries, overrides: overrides)
        XCTAssertEqual(snapshot.sceneMetaByHash[hash]?.title, "내가 고친 제목")
        XCTAssertTrue(snapshot.sceneMetaByHash[hash]?.titleUserEdited == true)
    }

    func test_사건_중요도_오버라이드() {
        let outline = DocumentOutline.parse(body3)
        let hash = outline.scenes[0].contentHash
        let event = StoryEvent(
            sceneHash: hash, participants: [서연.id], summary: "서연이 퇴원했다", importance: 2)
        let overrides = NarrativeOverrides([
            NarrativeOverride(kind: .eventImportance, key: event.stableKey, value: "5")
        ])
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            events: [hash: [event]], overrides: overrides)
        XCTAssertEqual(snapshot.events.first?.importance, 5)
        XCTAssertEqual(snapshot.sceneImportance(of: hash), 5)
    }

    func test_씬유형_오버라이드가_브랜치를_만든다() {
        let outline = DocumentOutline.parse(body3)
        let hash = outline.scenes[1].contentHash
        let overrides = NarrativeOverrides([
            NarrativeOverride(kind: .sceneType, key: hash, value: "회상")
        ])
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:], overrides: overrides)
        XCTAssertEqual(snapshot.branches.count, 1)
        XCTAssertEqual(snapshot.branches[0].sceneRange, 1..<2)
        XCTAssertEqual(snapshot.branches[0].type, .flashback)
        // 시간 순서: 과거 브랜치가 앞으로.
        XCTAssertEqual(snapshot.chronologicalSceneOrder(), [1, 0, 2])
    }

    func test_오버라이드_재앵커_씬수정후에도_살아남는다() {
        let outline = DocumentOutline.parse(body3)
        let oldHash = "죽은해시"
        let overrides = NarrativeOverrides([
            NarrativeOverride(
                kind: .sceneTitle, key: oldHash, value: "지킬 제목",
                anchor: "민준이 어린 시절을 떠올렸다")
        ])
        let (rekeyed, stale) = overrides.rekeyedForScenes(outline: outline, body: body3)
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(
            rekeyed.value(.sceneTitle, key: outline.scenes[1].contentHash), "지킬 제목")
    }

    func test_오버라이드_재앵커실패는_stale로_보존() {
        let outline = DocumentOutline.parse(body3)
        let overrides = NarrativeOverrides([
            NarrativeOverride(
                kind: .sceneTitle, key: "죽은해시", value: "지킬 제목",
                anchor: "원문에서 사라진 문장")
        ])
        let (rekeyed, stale) = overrides.rekeyedForScenes(outline: outline, body: body3)
        XCTAssertEqual(stale.count, 1)
        // 지워지지 않고 보존된다 — 원문이 돌아오면 다시 산다.
        XCTAssertEqual(rekeyed.all.count, 1)
    }

    // MARK: - 저장 왕복 (요구사항 §5 migration/backward compat)

    func test_JournalEntry_오버라이드없는_구파일_디코딩() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","title":"구버전","createdAt":"2025-01-01T00:00:00Z","body":"본문"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(JournalEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(entry.narrativeOverrides)
    }

    func test_사이드카_v4_왕복과_구버전폐기() throws {
        var sidecar = KnowledgeSidecar(entryID: UUID())
        sidecar.insights["h1"] = SceneInsights(
            knowledge: [
                KnowledgeDelta(characterID: 서연.id, stance: .hides, fact: "비밀", sceneHash: "h1")
            ],
            // ISO8601 저장은 소수초를 버린다 — 왕복 비교를 위해 초 단위 시각.
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(KnowledgeSidecar.self, from: data)
        XCTAssertEqual(decoded, sidecar)
        // 구버전은 로드 시 폐기·재구축 대상이다 (v8: stable project/document scope).
        XCTAssertEqual(KnowledgeSidecar.currentSchemaVersion, 8)
    }

    // MARK: - 컨텍스트 조립 (요구사항 §16·§17)

    func test_조립_리포트가_앎과_지금장면을_담는다() {
        let outline = DocumentOutline.parse(body3)
        let scenes = outline.scenes
        let h1 = scenes[0].contentHash
        let h3 = scenes[2].contentHash
        let insights: [String: SceneInsights] = [
            h1: SceneInsights(knowledge: [
                KnowledgeDelta(characterID: 서연.id, stance: .suspects, fact: "약이 바뀌었다", sceneHash: h1)
            ])
        ]
        let sceneSummaries: [String: KnowledgeSidecar.SceneSummary] = [
            h3: .init(contentHash: h3, headingPath: ["3장"], summary: "재회.", title: "카페의 재회")
        ]
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline,
            summariesByHash: [h1: "퇴원."],
            sceneSummaries: sceneSummaries, insights: insights)
        let document = DocumentContext(
            title: "시험작", kind: .novel, characters: [서연, 민준])
        // 커서를 3장 안에 — 1장은 창 밖(B 블록 대상).
        let cursor = scenes[2].utf16Range.lowerBound + 10
        let (prompt, report) = ContextAssembler.assembleWithReport(
            prefix: "카페에서 ",
            document: document,
            knowledge: snapshot,
            prefixStartUTF16: cursor,
            style: .continuation)
        guard case .continuation(let text) = prompt else {
            return XCTFail("continuation이어야 한다")
        }
        // 앎이 태도 문장으로 카드 줄에 실렸고, 리포트에도 같은 내용이 있다.
        XCTAssertTrue(text.contains("서연은 의심한다 — 약이 바뀌었다."))
        XCTAssertTrue(report.items.contains { $0.kind == .knowledge })
        // 지금 장면(제목)이 실렸다.
        XCTAssertTrue(text.contains("지금 장면: 카페의 재회"))
        XCTAssertTrue(report.items.contains { $0.kind == .currentScene })
        // 리포트의 모든 텍스트가 실제 프롬프트에 존재한다 (거울 불변식).
        for item in report.items where item.kind != .knowledge && item.kind != .state
            && item.kind != .recentEvent
        {
            XCTAssertTrue(
                text.contains(item.text),
                "리포트 항목이 프롬프트에 없다: \(item.text)")
        }
    }

}
