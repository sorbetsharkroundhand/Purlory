@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// StateDelta 파싱·fold 회귀 테스트 (M6-5b, PLAN §6.2·§8).
///
/// 전부 결정적 로직(파서·질의)이라 모델 없이 돈다 — 5a가 스크래치 검증으로
/// 때웠던 것을 테스트 타깃이 생긴 지금은 그물로 남긴다 (docs/m6-events.md).
/// `swift test`로 돈다 — MLX 커널을 건드리지 않아 metallib 없이 안전하다.
final class StateDeltaTests: XCTestCase {

    // MARK: - 픽스처

    private let seoyeon = CharacterCard(name: "서연", aliases: "연이, 서 대리")
    private let minjun = CharacterCard(name: "민준")

    private var nameIndex: [String: UUID] {
        EventParser.nameIndex([seoyeon, minjun])
    }

    private func parseOne(_ line: String) -> StoryEvent? {
        EventParser.parse(line, sceneHash: "h1", nameIndex: nameIndex).first
    }

    // MARK: - 파서: 상태 필드

    func test정상_상태_파싱() {
        let event = parseOne(
            "서연이 병원에 실려갔다 | 참여: 서연 | 중요도: 4 | 상태: 서연 위치=병원; 서연 감정=불안")
        XCTAssertEqual(event?.deltas.count, 2)
        XCTAssertEqual(event?.deltas[0].field, .location)
        XCTAssertEqual(event?.deltas[0].value, "병원")
        XCTAssertEqual(event?.deltas[0].characterID, seoyeon.id)
        XCTAssertEqual(event?.deltas[1].field, .emotion)
        XCTAssertEqual(event?.deltas[1].value, "불안")
        XCTAssertEqual(event?.deltas[0].sceneHash, "h1")
    }

    func test환각_인물_델타는_버린다() {
        // 등록 카드에 없는 이름 — 사건 참여자와 같은 관문 (docs/m6-events.md 결정 2).
        let event = parseOne("싸움이 났다 | 중요도: 3 | 상태: 지훈 감정=분노")
        XCTAssertEqual(event?.deltas, [])
    }

    func test닫힌_필드_집합_밖은_버린다() {
        // "기분"은 스키마에 없다 — 소형 모델의 자유 서술 차단 (PLAN §6.2).
        let event = parseOne("좋은 일이 있었다 | 중요도: 2 | 상태: 서연 기분=좋음; 서연 감정=기쁨")
        XCTAssertEqual(event?.deltas.count, 1)
        XCTAssertEqual(event?.deltas[0].field, .emotion)
    }

    func test값은_40자_clamp() {
        let long = String(repeating: "가", count: 60)
        let event = parseOne("사건이 있었다 | 상태: 서연 목표=\(long)")
        XCTAssertEqual(event?.deltas[0].value.count, EventParser.maxDeltaValueCharacters)
    }

    func test조사_붙은_이름과_별칭_매칭() {
        // "연이의"도 별칭 "연이" 접두 매칭으로 받아준다 (교착어 대응).
        let event = parseOne("연이가 집에 돌아왔다 | 상태: 연이의 위치=집")
        XCTAssertEqual(event?.deltas.first?.characterID, seoyeon.id)
    }

    func test쉼표_구분도_받아준다() {
        // 프롬프트는 `;`를 시키지만 모델이 `,`를 쓰는 경우까지 수용.
        let event = parseOne("이사했다 | 상태: 서연 위치=서울, 민준 감정=서운함")
        XCTAssertEqual(event?.deltas.count, 2)
    }

    func test깨진_조각은_조용히_버린다() {
        // `=` 없음 · 이름 없음 · 값 없음 — 조각 하나의 실패가 사건을 죽이지 않는다.
        let event = parseOne("사건이 있었다 | 상태: 서연 감정 우울; 위치=병원; 서연 위치=; 민준 생사=생존")
        XCTAssertEqual(event?.deltas.count, 1)
        XCTAssertEqual(event?.deltas[0].field, .vitality)
        XCTAssertEqual(event?.deltas[0].characterID, minjun.id)
    }

    func test델타_상한_4개() {
        let event = parseOne(
            "모든 것이 바뀌었다 | 상태: 서연 위치=a; 서연 감정=b; 서연 관계=c; 서연 목표=d; 민준 위치=e; 민준 감정=f")
        XCTAssertEqual(event?.deltas.count, EventParser.maxDeltasPerEvent)
    }

    func test상태가_바뀐_인물은_참여자로_승격된다() {
        // 참여 표기에 빠진 인물도 델타가 있으면 역색인에 걸려야 한다 —
        // 아니면 그 인물의 `state_at`이 이 사건을 영영 못 본다.
        let event = parseOne("서연이 민준을 떠났다 | 참여: 서연 | 상태: 민준 감정=상실감")
        XCTAssertEqual(Set(event?.participants ?? []), Set([seoyeon.id, minjun.id]))
    }

    func test상태_항목이_없으면_델타_없음() {
        // 5a 형식 그대로의 줄 — 기존 동작 유지.
        let event = parseOne("서연이 퇴원했다 | 참여: 서연 | 중요도: 3")
        XCTAssertEqual(event?.deltas, [])
    }

    // MARK: - fold 질의: stateAt(of:before:)

    /// 씬 3개 픽스처 — 1장(집·기대) → 2장(병원) → 3장(민준 사망).
    private func makeSnapshot() -> (KnowledgeSnapshot, DocumentOutline) {
        let body = """
            # 1장
            서연은 집에서 여행 준비를 했다. 설레는 마음으로 짐을 쌌다.
            # 2장
            서연은 갑작스런 통증으로 병원에 실려갔다. 민준이 곁을 지켰다.
            # 3장
            민준은 사고로 세상을 떠났다. 서연은 홀로 남았다.
            """
        let outline = DocumentOutline.parse(body)
        let hashes = outline.scenes.map(\.contentHash)
        let events: [String: [StoryEvent]] = [
            hashes[0]: [
                StoryEvent(
                    sceneHash: hashes[0], participants: [seoyeon.id],
                    summary: "서연이 여행 준비를 했다", importance: 2,
                    deltas: [
                        StateDelta(characterID: seoyeon.id, field: .location, value: "집", sceneHash: hashes[0]),
                        StateDelta(characterID: seoyeon.id, field: .emotion, value: "기대", sceneHash: hashes[0]),
                    ])
            ],
            hashes[1]: [
                StoryEvent(
                    sceneHash: hashes[1], participants: [seoyeon.id, minjun.id],
                    summary: "서연이 병원에 실려갔다", importance: 4,
                    deltas: [
                        StateDelta(characterID: seoyeon.id, field: .location, value: "병원", sceneHash: hashes[1])
                    ])
            ],
            hashes[2]: [
                StoryEvent(
                    sceneHash: hashes[2], participants: [minjun.id],
                    summary: "민준이 세상을 떠났다", importance: 5,
                    deltas: [
                        StateDelta(characterID: minjun.id, field: .vitality, value: "사망", sceneHash: hashes[2])
                    ])
            ],
        ]
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline,
            summariesByHash: [:], events: events)
        return (snapshot, outline)
    }

    func test나중_델타가_이긴다() {
        let (snapshot, outline) = makeSnapshot()
        let cursor = outline.scenes[1].utf16Range.upperBound
        let state = snapshot.stateAt(of: seoyeon.id, before: cursor)
        XCTAssertEqual(state[.location], "병원")  // 1장의 "집"을 2장이 덮는다
        XCTAssertEqual(state[.emotion], "기대")  // 갱신 없는 필드는 유지된다
    }

    func test시점_차단_커서_이후_델타_미누출() {
        // 2장을 고치는 중에 3장의 죽음이 새어 들면 안 된다 (CLAUDE.md §2-4).
        let (snapshot, outline) = makeSnapshot()
        let cursor = outline.scenes[1].utf16Range.upperBound
        XCTAssertNil(snapshot.stateAt(of: minjun.id, before: cursor)[.vitality])

        let end = outline.scenes[2].utf16Range.upperBound
        XCTAssertEqual(snapshot.stateAt(of: minjun.id, before: end)[.vitality], "사망")
    }

    func test끝나지_않은_씬의_델타는_제외() {
        // 커서가 2장 중간이면 2장은 아직 "끝난 씬"이 아니다 — 원문이 C 창에 있다.
        let (snapshot, outline) = makeSnapshot()
        let cursor = outline.scenes[1].utf16Range.lowerBound + 5
        XCTAssertEqual(snapshot.stateAt(of: seoyeon.id, before: cursor)[.location], "집")
    }

    func test톰스톤_아웃라인에_없는_해시는_제외() {
        // 블록이 수정돼 고아가 된 해시의 델타는 질의에서 이미 빠진다 (PLAN §8).
        let (_, outline) = makeSnapshot()
        let ghost = StoryEvent(
            sceneHash: "죽은해시", participants: [seoyeon.id],
            summary: "지워진 장면의 사건", importance: 5,
            deltas: [
                StateDelta(characterID: seoyeon.id, field: .vitality, value: "사망", sceneHash: "죽은해시")
            ])
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline,
            summariesByHash: [:], events: ["죽은해시": [ghost]])
        XCTAssertEqual(snapshot.stateAt(of: seoyeon.id, before: .max), [:])
    }

    func test미등록_인물은_빈_상태() {
        let (snapshot, _) = makeSnapshot()
        XCTAssertEqual(snapshot.stateAt(of: UUID(), before: .max), [:])
    }

    // MARK: - 카드 조립: 상태 산문 절

    func test카드에_상태가_산문으로_붙는다() {
        let (snapshot, outline) = makeSnapshot()
        let document = DocumentContext(
            title: "시험작", kind: .novel, characters: [seoyeon, minjun])
        let header = ContextAssembler.headerText(
            document: document, window: "",
            knowledge: snapshot, windowStart: outline.scenes[1].utf16Range.upperBound)
        // CaseIterable 순서 고정 렌더링 — KV 프리픽스 안정 (PLAN §12).
        // 레코드(`필드=값`)가 아니라 자연 문장으로 펴진다 (PLAN §11 형식 개편).
        XCTAssertTrue(header.contains("지금 병원에 있다"), header)
        XCTAssertTrue(header.contains("마음은 기대다"), header)
        XCTAssertFalse(header.contains("="), "레코드 구분자는 산문형에서 사라진다")
        XCTAssertFalse(header.contains("@커서"), header)
        // 3장(커서 이후)의 죽음은 카드에 없어야 한다.
        XCTAssertFalse(header.contains("사망"), header)
    }

    func test상태가_없으면_상태_절도_없다() {
        let (snapshot, outline) = makeSnapshot()
        let document = DocumentContext(
            title: "시험작", kind: .novel, characters: [minjun])
        let header = ContextAssembler.headerText(
            document: document, window: "",
            knowledge: snapshot, windowStart: outline.scenes[0].utf16Range.upperBound)
        XCTAssertFalse(header.contains("몸은"), header)
        XCTAssertFalse(header.contains("마음은"), header)
    }

    func test사망_델타는_등장불가_문장이_된다() {
        // 일관성 실탄 — "생사=사망" 레코드보다 문장이 모델을 더 세게 묶는다.
        let (snapshot, outline) = makeSnapshot()
        let document = DocumentContext(
            title: "시험작", kind: .novel, characters: [minjun])
        let header = ContextAssembler.headerText(
            document: document, window: "",
            knowledge: snapshot, windowStart: outline.scenes[2].utf16Range.upperBound)
        XCTAssertTrue(header.contains("민준은 이미 죽어 있다"), header)
    }
}
