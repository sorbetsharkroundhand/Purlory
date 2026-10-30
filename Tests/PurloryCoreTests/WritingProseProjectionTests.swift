@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class WritingProseProjectionTests: XCTestCase {
    func testProseExclusionsAndReversibleOffsets() throws {
        let source = """
        # 제목
        - 할**수** 있다. `제외코드` [보이는 말](https://excluded.invalid)
        <p align="center"><font color="#FF0000" size="18">붉은 *문장*</font></p>
        ```
        제외펜스
        ```
        ![제외그림](image.png)
        앞 $제외수식$ 뒤
        $$
        제외표시수식
        $$
        """
        let index = WritingProjectionIndex()
        index.reset(source: source)
        let windows = Array(index.windows(intersecting: .init(location: 0, length: source.utf16.count)))
        let prose = windows.map(\.text).joined()
        for expected in ["제목", "할수 있다.", "보이는 말", "붉은 문장", "앞", "뒤"] {
            XCTAssertTrue(prose.contains(expected), expected)
        }
        for excluded in ["제외", "https://", "image.png", "font", "align", "**"] {
            XCTAssertFalse(prose.contains(excluded), excluded)
        }
        let window = try XCTUnwrap(windows.first)
        let formatted = (window.text as NSString).range(of: "할수")
        let ranges = try XCTUnwrap(index.sourceRanges(for: .init(formatted), in: window))
        XCTAssertEqual(ranges.map { (source as NSString).substring(with: $0.nsRange) }, ["할", "수"])
        XCTAssertNil(window.contiguousSourceRange(for: .init(formatted)))
        let label = (window.text as NSString).range(of: "보이는 말")
        let labelRange = try XCTUnwrap(window.contiguousSourceRange(for: .init(label)))
        XCTAssertEqual((source as NSString).substring(with: labelRange.nsRange), "보이는 말")
    }

    func testDuplicateFormattedAndEmojiSpans() throws {
        let source = "**같은 말** 🙂한\n같은 말 🙂한"
        let index = WritingProjectionIndex()
        index.reset(source: source)
        let window = try XCTUnwrap(index.windows(intersecting: .init(location: 0, length: source.utf16.count)).first)
        let ns = window.text as NSString
        let first = ns.range(of: "같은 말")
        let second = ns.range(of: "같은 말", range: NSRange(location: NSMaxRange(first), length: ns.length - NSMaxRange(first)))
        let a = try XCTUnwrap(window.contiguousSourceRange(for: .init(first)))
        let b = try XCTUnwrap(window.contiguousSourceRange(for: .init(second)))
        XCTAssertNotEqual(a.location, b.location)
        XCTAssertEqual(a.location, 2)
        XCTAssertEqual(b.location, (source as NSString).range(of: "\n").location + 1)
        let emoji = ns.range(of: "🙂한")
        let mapped = try XCTUnwrap(window.contiguousSourceRange(for: .init(emoji)))
        XCTAssertEqual((source as NSString).substring(with: mapped.nsRange), "🙂한")
        XCTAssertNil(window.contiguousSourceRange(for: .init(location: ns.length, length: 1)))
    }

    func testSharedInlineScannerPreservesNestedFontAndCodeSemantics() {
        let source = "<font size=\"18\" color=\"#ab12ef\">***굵게*** `*코드*`</font> 끝"
        let spans = MarkdownInlineScanner.scan(source)
        let parsed = InlineMarkdown.parse(source)
        XCTAssertEqual(spans.map(\.text), parsed.map(\.text))
        XCTAssertEqual(spans.map(\.text).joined(), "굵게 *코드* 끝")
        XCTAssertEqual(spans.first?.style.color, "AB12EF")
        XCTAssertTrue(spans.first?.style.bold == true)
        XCTAssertTrue(spans.first?.style.italic == true)
        XCTAssertEqual(spans.first?.style.fontSize, 18)
        XCTAssertEqual(spans.first { $0.style.code }?.text, "*코드*")
        for span in spans {
            XCTAssertEqual((source as NSString).substring(with: span.sourceRange), span.text)
        }
    }

    func testMixedMarkupMapsAreExactAndSourceIsRetained() throws {
        let fragments = ["일반 문장🙂한 ", "할**수** 있다. ", "`코드` ",
                         "[**말**](https://example.invalid) ", "$x_y$ ", "![그림](asset.png) ",
                         "<font size=\"18\">가 *나*</font> ", "\n```\n코드\n```\n", "\n$$\nx\n$$\n"]
        var seed: UInt64 = 42
        for _ in 0..<20 {
            let source = (0..<100).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return fragments[Int(seed % UInt64(fragments.count))]
            }.joined()
            let blocks = WritingProseProjection.blocks(source: source)
            XCTAssertEqual(blocks.map(\.sourceText).joined(), source)
            XCTAssertTrue(blocks.allSatisfy(\.hasValidMap))
            let index = WritingProjectionIndex()
            index.reset(source: source)
            for window in index.windows(intersecting: .init(location: 0, length: source.utf16.count)) {
                for segment in window.segments where segment.eligible {
                    let mapped = try XCTUnwrap(window.contiguousSourceRange(for: .init(segment.prose)))
                    XCTAssertEqual(Array((source as NSString).substring(with: mapped.nsRange).utf16),
                                   Array((window.text as NSString).substring(with: segment.prose).utf16))
                }
            }
        }
    }

    func testProjectionSharesMathAndBlockDelimiterSemantics() throws {
        let source = ">literal\n$$$\n이어지는 문장\n  $$\n숨긴수식\n$$\n달러 \\$x\\$ 와 $5와 $10. $x$ 뒷문장"
        let index = WritingProjectionIndex()
        index.reset(source: source)
        let prose = index.windows(intersecting: .init(location: 0, length: source.utf16.count)).map(\.text).joined()
        XCTAssertTrue(prose.contains(">literal"))
        XCTAssertTrue(prose.contains("이어지는 문장"))
        XCTAssertFalse(prose.contains("숨긴수식"))
        XCTAssertTrue(prose.contains("\\$x\\$"))
        XCTAssertTrue(prose.contains("$5와 $10"))
        XCTAssertTrue(prose.contains("뒷문장"))
        let sourceMath = (source as NSString).range(of: "$x$", options: .backwards)
        for window in index.windows(intersecting: .init(location: 0, length: source.utf16.count)) {
            XCTAssertFalse(window.segments.contains { $0.eligible && NSIntersectionRange($0.source, sourceMath).length > 0 })
        }
    }

    func testBalancedLinkAndImageDestinationsNeverBecomeProse() {
        for source in ["[보이는 말](https://example.invalid/(x)/비밀주소 \"비밀제목\") 끝",
                       "[보이는 말](<https://example.invalid/비밀주소>) 끝",
                       "![비밀설명](folder/(x)/비밀주소.png){width=120} 끝"] {
            let index = WritingProjectionIndex()
            index.reset(source: source)
            let prose = index.windows(intersecting: .init(location: 0, length: source.utf16.count)).map(\.text).joined()
            XCTAssertTrue(prose.contains("끝"))
            XCTAssertFalse(prose.contains("비밀"))
            XCTAssertFalse(prose.contains("width"))
            if !source.hasPrefix("!") { XCTAssertTrue(prose.contains("보이는 말")) }
        }
        for malformed in ["[말\\", "[말](주소\\", "[말](주소 \"제목\\"] {
            let blocks = WritingProseProjection.blocks(source: malformed)
            XCTAssertEqual(blocks.map(\.sourceText).joined(), malformed)
            XCTAssertTrue(blocks.allSatisfy(\.hasValidMap))
        }
    }

    func testSharedReferenceScannersRejectTrailingEscapes() {
        let label = "말\\"[...], destination = "주소\\"[...], title = "\"제목\\"[...]
        XCTAssertNil(ImageReferenceParser.scanAlt(label, from: label.startIndex))
        XCTAssertNil(ImageReferenceParser.scanPlainDestination(destination, from: destination.startIndex))
        XCTAssertNil(ImageReferenceParser.scanUntilUnescaped(destination, from: destination.startIndex, stoppingAt: ">"))
        XCTAssertNil(ImageReferenceParser.scanTitle(title, from: title.startIndex))
    }
}
