@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// 서사 구간 분석 회귀 테스트 (요구사항 §7–§10, PLAN §6.5).
/// **과거형 ≠ 회상**의 원칙 위에서, LLM 게이트(표지 감지)와 파서 검증
/// (환각 경계 차단·복귀 불확실 보존·깊이 스택)를 고정한다.
final class SegmentAnalysisTests: XCTestCase {

    private let scene =
        "남편은 창밖을 보았다. 어린 시절이 떠올랐다. 시골 길을 걸었다. 소년은 웃었다. "
        + "다시 방 안이었다. 아내가 말을 걸었다."

    // MARK: - 1단: 결정적 후보 감지 (LLM 호출 게이트)

    func test시간이동_표지가_있으면_후보다() {
        XCTAssertTrue(TemporalShiftDetector.hasCandidate(in: "그날 밤이 떠올랐다."))
        XCTAssertTrue(TemporalShiftDetector.hasCandidate(in: "꿈속에서 그녀를 만났다."))
    }

    func test과거형만으로는_후보가_아니다() {
        // 한국어 서술 자체가 과거형이다 — 시제는 표지가 아니다 (요구사항 §7).
        XCTAssertFalse(TemporalShiftDetector.hasCandidate(in: "그는 산을 걸었다. 정상에서 바라보았다."))
        XCTAssertFalse(TemporalShiftDetector.hasCandidate(in: "아내가 말을 걸었다. 남편은 대답했다."))
    }

    // MARK: - 3단: 구간 파서

    func test회상_구간을_위치까지_확정한다() {
        let output = """
        구간: 층=회상 | 시작="어린 시절이 떠올랐다" | 끝="다시 방 안이었다" | 복귀=확인 \
        | 깊이=1 | 시점=남편 | 출처=기억 | 신뢰=유력
        """
        let ns = scene as NSString
        let segments = SegmentParser.parse(output, sceneHash: "h", sceneText: scene)

        XCTAssertEqual(segments.count, 1)
        let segment = segments[0]
        XCTAssertEqual(segment.layer, .flashback)
        XCTAssertEqual(segment.localStart, ns.range(of: "어린 시절이 떠올랐다").location)
        XCTAssertEqual(
            segment.localEnd,
            ns.range(of: "다시 방 안이었다").location + ns.range(of: "다시 방 안이었다").length)
        XCTAssertEqual(segment.returnState, .found)
        XCTAssertEqual(segment.endQuote, "다시 방 안이었다")
        XCTAssertEqual(segment.pov, "남편")
        XCTAssertEqual(segment.subjectCharacter, "남편") // 인물 생략 — 시점이 기본
        XCTAssertEqual(segment.source, .memory)
        XCTAssertEqual(segment.reliability, .probable)
        XCTAssertEqual(segment.confidence, 0.8)
        XCTAssertNil(segment.parentID) // 깊이 1 — 부모 없음
    }

    func test환각_시작_인용은_구간째_버린다() {
        let output = "구간: 층=회상 | 시작=\"원문에 전혀 없는 시작 문장입니다\""
        XCTAssertTrue(SegmentParser.parse(output, sceneHash: "h", sceneText: scene).isEmpty)
    }

    func test현재_층은_구간을_만들지_않는다() {
        // 씬 바탕이 이미 현재다 — "현재" 줄은 구간이 아니라 소음.
        let output = "구간: 층=현재 | 시작=\"어린 시절이 떠올랐다\""
        XCTAssertTrue(SegmentParser.parse(output, sceneHash: "h", sceneText: scene).isEmpty)
    }

    func test끝을_못_찾으면_uncertain으로_씬끝까지_잠정범위() {
        // 임의로 씬 끝까지 회상이라 확정하지 않는다 — 불확실 표시가 규격이다.
        let output = "구간: 층=회상 | 시작=\"어린 시절이 떠올랐다\" | 끝=\"원문에 없는 마무리 문장입니다\" | 복귀=확인"

        let segment = SegmentParser.parse(output, sceneHash: "h", sceneText: scene)[0]

        XCTAssertEqual(segment.returnState, .uncertain)
        XCTAssertNil(segment.endQuote)
        XCTAssertEqual(segment.localEnd, (scene as NSString).length)
        XCTAssertEqual(segment.confidence, 0.55)
    }

    func test중첩_구간은_깊이_스택으로_부모를_잦는다() {
        let output = """
        구간: 층=회상 | 시작="어린 시절이 떠올랐다" | 깊이=1
        구간: 층=꿈 | 시작="소년은 웃었다" | 깊이=2
        """
        let segments = SegmentParser.parse(output, sceneHash: "h", sceneText: scene)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].depth, 1)
        XCTAssertEqual(segments[1].parentID, segments[0].id)
    }

    func test한_씬의_구간은_최대_여섯개() {
        let longScene = (0..<8).map { "\($0)번째 문장이 여기 있다." }.joined(separator: " ")
        let output = (0..<8).map { "구간: 층=회상 | 시작=\"\($0)번째 문장이 여기\"" }
            .joined(separator: "\n")

        XCTAssertEqual(SegmentParser.parse(output, sceneHash: "h", sceneText: longScene).count, 6)
    }

    // MARK: - 보조 단위

    func test따옴표_벗기기와_토막_거부() {
        XCTAssertEqual(SegmentParser.unquote("\"인용문입니다\""), "인용문입니다")
        XCTAssertEqual(SegmentParser.unquote("「꺾쇠 인용입니다」"), "꺾쇠 인용입니다")
        XCTAssertNil(SegmentParser.unquote("짧")) // 4자 미만 — 앵커로 못 쓴다
    }

    func test인용_꼬리가_달라도_앞열두글자로_찾는다() {
        // 모델이 끝을 다듬는 습관 대응 — 12글자 접두 매칭 폴백.
        let text = "앞부분열두글자가원문에있다" as NSString
        let query = "앞부분열두글자가원문에있" + "모델이 덧붙인 엉뚱한 꼬리"
        let found = SegmentParser.locate(query, in: text)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.location, 0)
    }

    // MARK: - 사용자 경계 수정 (요구사항 §15)

    func test시작_경계_수정이_적용된다() throws {
        let outline = DocumentOutline.parse(scene)
        let hash = try XCTUnwrap(outline.scenes.first?.contentHash)
        var segment = NarrativeSegment(
            sceneHash: hash, localStart: 5, localEnd: 30,
            startQuote: "낡은 시작", layer: .flashback, persistentID: "seg-1")
        segment.localEnd = 40

        let overrides = NarrativeOverrides([
            NarrativeOverride(kind: .segmentStart, key: "seg-1", value: "\"다시 방 안이었다\""),
        ])
        let applied = SegmentParser.applyingBoundaryOverrides(
            [hash: SceneSegmentation(segments: [segment])],
            overrides: overrides, outline: outline, body: scene)

        let updated = try XCTUnwrap(applied[hash]?.segments.first)
        XCTAssertEqual(
            updated.localStart, (scene as NSString).range(of: "다시 방 안이었다").location)
        XCTAssertEqual(updated.confidence, 1) // 사용자 판정 = 확정
        XCTAssertEqual(updated.localEnd, 40)  // 건드리지 않은 쪽은 유지
    }

    func test못_찾는_경계_수정은_무시한다() throws {
        // stale이 오적용보다 낫다 — 기존 경계를 유지한다.
        let outline = DocumentOutline.parse(scene)
        let hash = try XCTUnwrap(outline.scenes.first?.contentHash)
        let segment = NarrativeSegment(
            sceneHash: hash, localStart: 5, localEnd: 30,
            startQuote: "낡은 시작", layer: .flashback, persistentID: "seg-1")

        let overrides = NarrativeOverrides([
            NarrativeOverride(kind: .segmentStart, key: "seg-1", value: "\"원문에 없는 문장입니다\""),
        ])
        let applied = SegmentParser.applyingBoundaryOverrides(
            [hash: SceneSegmentation(segments: [segment])],
            overrides: overrides, outline: outline, body: scene)

        XCTAssertEqual(applied[hash]?.segments.first?.localStart, 5)
    }
}
