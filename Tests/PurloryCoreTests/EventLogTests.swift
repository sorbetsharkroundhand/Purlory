@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 사건 로그 파서 회귀 테스트 (PLAN §6.3, docs/m6-events.md).
/// 델타 세부는 StateDeltaTests, 근거 검증·중복 제거는 NarrativeIntelligenceTests가
/// 담당한다 — 여기선 **줄 한 줄이 사건이 되기까지의 관문**(참여 resolve·중요도
/// clamp·상한·형식 게이트)을 고정한다.
final class EventLogTests: XCTestCase {

    private let seoyeon = UUID()
    private let minjun = UUID()

    private var index: [String: UUID] {
        ["서연": seoyeon, "민준": minjun]
    }

    func test사건_줄을_완전히_읽는다() {
        let scene = "그날 서연이 병원에서 퇴원했다."
        let output = "서연이 병원에서 퇴원했다 | 참여: 서연, 민준 | 중요도: 4 | 근거: \"퇴원했다\""

        let events = EventParser.parse(output, sceneHash: "h", nameIndex: index, sceneText: scene)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "서연이 병원에서 퇴원했다")
        XCTAssertEqual(Set(events[0].participants), [seoyeon, minjun])
        XCTAssertEqual(events[0].importance, 4)
        XCTAssertEqual(events[0].quote, "퇴원했다") // 원문 대조 통과 — 직접 근거
    }

    func test구분자없는_줄은_버리고_형식줄만_건진다() {
        // 머리말("다음은 사건입니다:")이 사건으로 저장되면 B 블록에 지식인 척
        // 주입된다 — `|` 없는 줄은 구조적으로 차단된다.
        let output = """
        다음은 사건입니다:
        서연이 집을 나섰다 | 중요도: 3
        """
        let events = EventParser.parse(output, sceneHash: "h", nameIndex: index)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "서연이 집을 나섰다")
    }

    func test환각_참여자만_버린다() {
        let events = EventParser.parse(
            "서연이 웃었다 | 참여: 서연, 유령", sceneHash: "h", nameIndex: ["서연": seoyeon])

        XCTAssertEqual(events[0].participants, [seoyeon])
    }

    func test조사가_붙어도_접두매칭으로_찾는다() {
        let events = EventParser.parse(
            "서연이 문을 닫았다 | 참여: 서연이", sceneHash: "h", nameIndex: index)

        XCTAssertEqual(events[0].participants, [seoyeon])
    }

    func test중요도는_1에서_5로_클램프된다() {
        let cases: [(String, Int)] = [
            ("9", 5), ("0", 1), ("높음", 3),  // 깨진 표기는 중간값
        ]
        for (raw, expected) in cases {
            let events = EventParser.parse(
                "서연이 결심했다 | 중요도: \(raw)", sceneHash: "h", nameIndex: index)
            XCTAssertEqual(events.first?.importance, expected, "중요도 \(raw)")
        }
    }

    func test한_씬에는_최대_세개까지만() {
        let output = (0..<5).map { "서연이 \($0)번째 방을 나섰다 | 중요도: 3" }
            .joined(separator: "\n")

        XCTAssertEqual(EventParser.parse(output, sceneHash: "h", nameIndex: index).count, 3)
    }

    func test토막_요약은_사건이_아니다() {
        XCTAssertTrue(EventParser.parse("웃다 | 참여: 서연", sceneHash: "h", nameIndex: index).isEmpty)
    }

    func test긴_요약은_80자에서_잘린다() {
        let long = String(repeating: "아주긴문장", count: 15) // 60자… 상한 여유
        let head = long + String(repeating: "더하기", count: 10) // 120자
        let events = EventParser.parse("\(head) | 참여: 서연", sceneHash: "h", nameIndex: index)

        XCTAssertEqual(events[0].summary.count, EventParser.maxSummaryCharacters)
        XCTAssertTrue(head.hasPrefix(events[0].summary))
    }

    // MARK: - 불릿 제거 (「날개」 회귀)

    func test불릿마커만_벗기고_숫자본문은_살린다() {
        XCTAssertEqual(EventParser.stripListMarker("- 항목"), "항목")
        XCTAssertEqual(EventParser.stripListMarker("* 항목"), "항목")
        XCTAssertEqual(EventParser.stripListMarker("• 항목"), "항목")
        XCTAssertEqual(EventParser.stripListMarker("1. 항목"), "항목")
        XCTAssertEqual(EventParser.stripListMarker("2) 항목"), "항목")
        // 선두 숫자를 뭉뚱거리면 본문을 먹는다 — 실제 원고 피해 사례.
        XCTAssertEqual(EventParser.stripListMarker("33번지 18가구"), "33번지 18가구")
        XCTAssertEqual(EventParser.stripListMarker("3.5초 만에"), "3.5초 만에")
        XCTAssertEqual(EventParser.stripListMarker("1930년에"), "1930년에")
    }
}
