@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// 씬 분할 회귀 테스트 (docs/m6-scene-split.md) — 전부 결정적, 모델 없음.
///
/// 최우선 불변조건: **세그먼트 이어붙이기 == 원문** (§3 — 시뮬레이션에서
/// 문자열 쪼개기로 개행을 유실한 전력이 있다. 원고 유실은 최악의 버그다).
final class SceneSplitTests: XCTestCase {

    /// 한국어 문장 뭉치로 지정 길이 이상의 본문을 만든다 (결정적).
    private func longProse(atLeast target: Int) -> String {
        let sentences = [
            "서연은 창밖을 오래 바라보았다.", "바람이 불자 나뭇잎이 흔들렸다.",
            "민준은 아무 말도 하지 않았다.", "골목 끝에서 개가 짖었다.",
            "저녁상 위의 국이 식어 갔다.", "시계가 아홉 번 울렸다.",
            "누군가 대문을 두드렸다!", "정말 이대로 괜찮은 걸까?",
            "그날의 약속은 아직 유효했다.", "빗방울이 유리창에 금을 그었다.",
        ]
        var text = ""
        var index = 0
        while text.count < target {
            text += sentences[index % sentences.count] + " "
            index += 1
        }
        return text
    }

    private func assertTiling(_ body: String, file: StaticString = #filePath, line: UInt = #line) {
        let outline = DocumentOutline.parse(body)
        let ns = body as NSString
        // 씬들이 서로 겹치지 않고 이어진다 (사이 틈은 서두 공백뿐일 수 있다).
        var previousEnd: Int?
        var reassembled = ""
        for scene in outline.scenes {
            if let previousEnd {
                XCTAssertEqual(
                    scene.utf16Range.lowerBound, previousEnd,
                    "씬 사이에 틈·겹침이 있다", file: file, line: line)
            }
            previousEnd = scene.utf16Range.upperBound
            reassembled += ns.substring(
                with: NSRange(
                    location: scene.utf16Range.lowerBound, length: scene.utf16Range.count))
        }
        // 서두(첫 씬 앞) 공백을 제외하면 원문과 동일해야 한다.
        let head = ns.substring(to: outline.scenes.first?.utf16Range.lowerBound ?? 0)
        XCTAssertEqual(head + reassembled, body, "세그먼트가 원문을 유실했다", file: file, line: line)
    }

    // MARK: - 타일링 무손실 (최우선)

    func test상한_초과_본문_타일링_무손실() {
        assertTiling(longProse(atLeast: 10_000))
    }

    func test헤딩_있는_장편_타일링_무손실() {
        let body = "# 1장\n" + longProse(atLeast: 6_000) + "\n# 2장\n" + longProse(atLeast: 4_000)
        assertTiling(body)
    }

    func test개행_뭉치_보존() {
        // 시뮬레이션에서 실제로 잃었던 케이스 — 헤딩 사이 빈 줄.
        let body = longProse(atLeast: 3_000) + "\n\n\n" + longProse(atLeast: 3_000)
        assertTiling(body)
    }

    func test공백_꼬리_보존() {
        assertTiling(longProse(atLeast: 2_000) + "   \n  ")
    }

    // MARK: - 크기 보장

    func test모든_세그먼트가_상한_이하() {
        let body = longProse(atLeast: 30_000)
        let outline = DocumentOutline.parse(body)
        XCTAssertGreaterThan(outline.scenes.count, 10)  // 실제로 쪼개졌는지
        for scene in outline.scenes {
            XCTAssertLessThanOrEqual(
                scene.utf16Range.count, DocumentOutline.maxSegmentUTF16,
                "세그먼트가 이해 상한을 넘으면 잘림이 되돌아온다")
        }
    }

    func test상한_이하_씬은_안_쪼갠다() {
        let body = "# 1장\n짧은 장면 하나.\n# 2장\n또 하나."
        let outline = DocumentOutline.parse(body)
        XCTAssertEqual(outline.scenes.count, 2)
        XCTAssertTrue(outline.scenes.allSatisfy { $0.segmentIndex == 0 })
    }

    // MARK: - 폴백 사슬 (§2.2 — 종결부호 없는 원고)

    func test종결부호_없는_본문도_상한_이하로() {
        // 쉼표·공백만 있는 만연체 — 어절 폴백이 받아야 한다.
        let body = String(
            repeating: "그리고 이어지는 말들이 끝나지 않은 채 계속 흘러가고, ", count: 200)
        assertTiling(body)
        let outline = DocumentOutline.parse(body)
        for scene in outline.scenes {
            XCTAssertLessThanOrEqual(scene.utf16Range.count, DocumentOutline.maxSegmentUTF16)
        }
    }

    func test공백조차_없는_본문은_강제_절단() {
        let body = String(repeating: "가나다라마바사", count: 500)  // 3,500자, 공백 0
        assertTiling(body)
        let outline = DocumentOutline.parse(body)
        XCTAssertGreaterThan(outline.scenes.count, 1)
        for scene in outline.scenes {
            XCTAssertLessThanOrEqual(scene.utf16Range.count, DocumentOutline.maxSegmentUTF16)
        }
    }

    // MARK: - 안정성 (CDC의 존재 이유)

    func test같은_입력은_같은_경계() {
        // FNV(프로세스 안정)라야 한다 — Hasher(랜덤 시드)면 실행마다 경계가
        // 바뀌어 매 실행 전체 재요약이 된다.
        let body = longProse(atLeast: 10_000)
        let first = DocumentOutline.parse(body).scenes.map(\.contentHash)
        let second = DocumentOutline.parse(body).scenes.map(\.contentHash)
        XCTAssertEqual(first, second)
    }

    func test끝쪽_편집은_앞쪽_세그먼트를_안_건드린다() {
        // CDC의 요점 — 편집 영향의 국소화 (CLAUDE.md §2-3 증분이 기본).
        let body = longProse(atLeast: 10_000)
        let before = DocumentOutline.parse(body).scenes
        let after = DocumentOutline.parse(body + "덧붙인 마지막 문장이다.").scenes
        // 앞 절반의 해시는 그대로여야 한다 (뒤에서만 달라진다).
        let half = before.count / 2
        XCTAssertEqual(
            before.prefix(half).map(\.contentHash),
            after.prefix(half).map(\.contentHash))
    }

    // MARK: - 세그먼트 메타

    func test세그먼트_순번과_헤딩_경로_공유() {
        let body = "# 1장\n" + longProse(atLeast: 6_000)
        let outline = DocumentOutline.parse(body)
        XCTAssertGreaterThan(outline.scenes.count, 2)
        for (index, scene) in outline.scenes.enumerated() {
            XCTAssertEqual(scene.segmentIndex, index)  // 한 장이라 전부 같은 경로
            XCTAssertEqual(scene.headingPath, ["1장"])
        }
    }

    func test숫자_소수점은_문장_경계가_아니다() {
        let pieces = DocumentOutline.sentencePieces(in: Substring("기록은 3.5초 만에 끝났다. 다음 기록."))
        // "3.5초"의 점에서 끊기면 조각이 3개 이상이 된다.
        XCTAssertEqual(pieces.count, 2)
    }
}
