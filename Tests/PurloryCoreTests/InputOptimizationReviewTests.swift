import AppKit
import XCTest
@testable import PurloryFoundation
@testable import PurloryWorkspaceUI

@MainActor
final class InputOptimizationReviewTests: XCTestCase {
    func testIndexedSourceCoordinatesMatchUncachedMapping() {
        let fixtures = [
            "# 제목\n첫 **굵은** 문장\n\n끝\n",
            "```swift\nlet a = 1\nlet b = 2\n```\n끝",
            "앞\n```\n코드\n```\n뒤\n```python\n마지막\n```",
            "> 인용\n- 항목\n  - 안쪽\n- [x] 완료\n![그림](asset.png)\n끝",
            "<p align=\"center\">가운데</p>\n앞 $x$ 뒤\n$$x^2$$\n끝",
            "$$\nx+y\nz+w\n$$\n끝", "", "\n", "끝", "끝\n\n"
        ]
        for fixture in fixtures {
            let editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 500))
            editor.textStorage?.delegate = editor
            editor.load(markdown: fixture)
            _ = editor.serializedSource()
            let text = editor.string as NSString
            let fast = (0...text.length).map { editor.sourceCursorOffset(at: $0) }
            var paragraphs: [NSRange] = [], cursor = 0
            while cursor < text.length {
                let range = text.paragraphRange(for: NSRange(location: cursor, length: 0))
                paragraphs.append(range); cursor = range.upperBound
            }
            let fastRanges = paragraphs.map { editor.originalParagraphRange(forNative: $0) }
            editor.invalidateSerialCache()
            let slow = (0...text.length).map { editor.sourceCursorOffset(at: $0) }
            let slowRanges = paragraphs.map { editor.originalParagraphRange(forNative: $0) }
            XCTAssertEqual(fast, slow, "Caret coordinates changed for \(fixture)")
            XCTAssertEqual(fastRanges, slowRanges, "Paragraph ownership changed for \(fixture)")
        }
    }

    func testStreamingSourceUtilitiesPreserveChunkBoundariesAndExactUnicode() {
        let chunks = ["- [제목] 첫", "째\r", "\n* [제", "목] 둘째\u{2028}[제목] \n다른 줄\n[제목] 셋째"]
        let source = DocumentSource(chunks: chunks)
        XCTAssertEqual(source.extractTaggedNoteLines(tagPrefix: "[제목]"), ["첫째", "둘째", "셋째"])
        XCTAssertTrue(source.utf8Equals(chunks.joined()))
        XCTAssertFalse(source.utf8Equals(chunks.joined() + "!"))
        XCTAssertFalse(DocumentSource(chunks: ["é가"]).utf8Equals("è가"))
        XCTAssertFalse(DocumentSource(chunks: ["e", "\u{301}"]).utf8Equals("é"))
        var expectedOffset = 0
        for index in chunks.indices {
            XCTAssertEqual(source.chunkOffset(at: index), expectedOffset)
            expectedOffset += chunks[index].utf16.count
        }
        XCTAssertEqual(source.chunkOffset(at: chunks.count), expectedOffset)
        XCTAssertEqual(source.materializationCount, 0)
    }
}
