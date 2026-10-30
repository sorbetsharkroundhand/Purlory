@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import Foundation
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// MathScanner golden 테스트 — 인라인 `$…$`, 한 줄 display `$$…$$`,
/// 이스케이프·통화 오인 방지 (이슈 #20 완료 조건 2).
final class MathScannerTests: XCTestCase {

    private func latexes(_ line: String, skipping skips: [NSRange] = []) -> [String] {
        MathScanner.regions(in: line, skipping: skips).map(\.latex)
    }

    private func kinds(_ line: String) -> [MathScanner.Region.Kind] {
        MathScanner.regions(in: line).map(\.kind)
    }

    // MARK: 인라인

    func test인라인_기본() {
        XCTAssertEqual(latexes("힘은 $E=mc^2$다"), ["E=mc^2"])
        XCTAssertEqual(kinds("힘은 $E=mc^2$다"), [.inlineText])
    }

    func test인라인_한글주변_두개() {
        XCTAssertEqual(latexes("값 $a_1$과 $b_2$가 다르다"), ["a_1", "b_2"])
    }

    func test인라인_문장부호와붙어도_된다() {
        XCTAssertEqual(latexes("($x+y$)"), ["x+y"])
    }

    func test통화는_수식이_아니다() {
        XCTAssertEqual(latexes("5달러는 $5이고 10달러는 $10이다"), [])
        XCTAssertEqual(latexes("가격 $5와 $10 비교"), [])
    }

    func test이스케이프된_달러는_구분자가_아니다() {
        XCTAssertEqual(latexes(#"\$x\$는 가격 표기"#), [])
        XCTAssertEqual(latexes(#"가격은 \$5이고 공식은 $x^2$이다"#), ["x^2"])
    }

    func test내용안의_이스케이프_달러() {
        XCTAssertEqual(latexes(#"$a\$b$"#), [#"a\$b"#])
    }

    func test공백경계는_실패한다() {
        XCTAssertEqual(latexes("$ x$"), [], "여는 $ 뒤 공백")
        XCTAssertEqual(latexes("$x $"), [], "닫는 $ 앞 공백")
        XCTAssertEqual(latexes("$$"), [], "빈 내용")
    }

    func test닫는달러_뒤숫자는_통화로_본다() {
        XCTAssertEqual(latexes("$x$5"), [])
    }

    func test짝없는_달러는_무시한다() {
        XCTAssertEqual(latexes("그의 전재산은 $1.50이었다"), [])
    }

    // MARK: display (한 줄)

    func test디스플레이_기본() {
        XCTAssertEqual(latexes("$$x^2$$"), ["x^2"])
        XCTAssertEqual(kinds("$$x^2$$"), [.displayLine])
    }

    func test디스플레이_공백허용() {
        XCTAssertEqual(latexes("$$ x + y $$"), ["x + y"])
    }

    func test디스플레이_문장속에서() {
        let regions = MathScanner.regions(in: "공식 $$E=mc^2$$ 임")
        XCTAssertEqual(regions.map(\.latex), ["E=mc^2"])
        XCTAssertEqual(regions.first?.range, NSRange(location: 3, length: 10))
    }

    func test빈디스플레이는_아니다() {
        XCTAssertEqual(latexes("$$$$"), [])
    }

    func test닫히지않는_디스플레이는_무시한다() {
        XCTAssertEqual(latexes("$$x^2"), [])
    }

    // MARK: 코드 스팬 제외

    func test코드스팬_제외범위() {
        let line = "`$x$`와 $y$"
        let tickRange = NSRange(location: 0, length: 5)  // `$x$` 전체
        XCTAssertEqual(MathScanner.regions(in: line, skipping: [tickRange]).count, 1)
        XCTAssertEqual(
            MathScanner.regions(in: line, skipping: [tickRange]).last?.latex, "y")
    }

    // MARK: 타이핑 변환 (커서 직전 닫힘)

    func testIncompleteDoubleDollarCandidateDoesNotCloseInlineMath() {
        for line in ["$$E=mc^2$", "한글 $$x^2$"] {
            XCTAssertEqual(MathScanner.regions(in: line), [])
            XCTAssertNil(MathScanner.closingInline(in: line, atCaret: line.utf16.count))
        }
        let complete = "$$E=mc^2$$"
        XCTAssertEqual(kinds(complete), [.displayLine])
        XCTAssertNil(MathScanner.closingInline(in: complete, atCaret: complete.utf16.count))
    }

    func testAdjacentInlineFormulasKeepDistinctDelimiterOwnership() {
        let line = "$x$$y$"
        XCTAssertEqual(latexes(line), ["x", "y"])
        XCTAssertEqual(kinds(line), [.inlineText, .inlineText])
        XCTAssertEqual(MathScanner.closingInline(in: line, atCaret: line.utf16.count)?.latex, "y")
        XCTAssertEqual(MathScanner.closingInline(in: line, atCaret: 3)?.latex, "x")
        let afterDisplay = "$$x$$$y$"
        XCTAssertEqual(latexes(afterDisplay), ["x", "y"])
        XCTAssertEqual(kinds(afterDisplay), [.displayLine, .inlineText])
        XCTAssertEqual(MathScanner.closingInline(in: afterDisplay, atCaret: afterDisplay.utf16.count)?.latex, "y")
    }

    func testEscapedDollarCanPrecedeASeparateInlineFormula() {
        let line = #"\$$x$"#
        XCTAssertEqual(latexes(line), ["x"])
        XCTAssertEqual(MathScanner.closingInline(in: line, atCaret: line.utf16.count)?.latex, "x")
    }

    func test타이핑_방금닫힌쌍만() {
        let line = "전기 $E=mc^2$"
        let caret = (line as NSString).length
        XCTAssertNotNil(MathScanner.closingInline(in: line, atCaret: caret))
        XCTAssertNil(MathScanner.closingInline(in: line, atCaret: caret - 1))
        XCTAssertNil(MathScanner.closingInline(in: line, atCaret: caret - 4))
    }

    func test타이핑_통화쌍은_닫힘이_아니다() {
        let line = "$5와 $10"
        let caret = (line as NSString).length
        XCTAssertNil(MathScanner.closingInline(in: line, atCaret: caret))
    }
}
