@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 타임라인 점프 스니펫 회귀 테스트 (M7) — 마크다운 오프셋에서 에디터
/// 스토리지에도 존재할 산문 토막을 뽑는지 고정한다.
final class JumpSnippetTests: XCTestCase {

    func test헤딩_마커는_건너뛴다() {
        // "# 1장"의 "#·공백"은 에디터 스토리지에 없다 — 제목 텍스트부터.
        let body = "# 1장\n서연은 창밖을 바라보았다."
        XCTAssertEqual(NarrativeView.jumpSnippet(in: body, atUTF16: 0), "1장")
    }

    func test본문_중간_위치() {
        let body = "앞 문장이다. 뒤 문장이 이어진다."
        let offset = ("앞 문장이다. " as NSString).length
        XCTAssertEqual(
            NarrativeView.jumpSnippet(in: body, atUTF16: offset), "뒤 문장이 이어진다.")
    }

    func test개행을_넘지_않는다() {
        // 줄을 넘겨 이어붙이면 스토리지에 없는 문자열이 된다.
        let body = "짧은 줄\n다음 줄의 긴 본문이 여기 이어진다."
        XCTAssertEqual(NarrativeView.jumpSnippet(in: body, atUTF16: 0), "짧은 줄")
    }

    func test긴_줄은_40으로_자른다() {
        let body = String(repeating: "가", count: 100)
        XCTAssertEqual(NarrativeView.jumpSnippet(in: body, atUTF16: 0)?.count, 40)
    }

    func test끝을_넘는_오프셋은_nil() {
        XCTAssertNil(NarrativeView.jumpSnippet(in: "짧다", atUTF16: 999))
    }

    func test공백뿐이면_nil() {
        XCTAssertNil(NarrativeView.jumpSnippet(in: "본문", atUTF16: 2))
    }
}
