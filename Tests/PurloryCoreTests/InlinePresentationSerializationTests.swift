@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class InlinePresentationSerializationTests: XCTestCase {
    func testFallbackFontDoesNotSplitOneOriginalFormattingSpan() {
        let text = "한글🙂"
        let storage = NSMutableAttributedString(string: text, attributes: [.purloryBold: true, .font: NSFont.systemFont(ofSize: 18)])
        let emoji = (text as NSString).range(of: "🙂")
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), range: emoji)
        var spans: [InlineMarkdown.SerializedSpan] = []
        let source = InlineMarkdown.serialize(storage, in: NSRange(location: 0, length: storage.length)) { spans.append($0) }
        XCTAssertEqual(source, "**한글🙂**")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.native, NSRange(location: 0, length: text.utf16.count))
        XCTAssertEqual(spans.first?.body, NSRange(location: 2, length: text.utf16.count))
    }

    func testRealFormattingBoundaryRemainsDistinct() {
        let storage = NSMutableAttributedString(string: "AB", attributes: [.purloryBold: true])
        storage.removeAttribute(.purloryBold, range: NSRange(location: 1, length: 1))
        storage.addAttribute(.purloryItalic, value: true, range: NSRange(location: 1, length: 1))
        XCTAssertEqual(InlineMarkdown.serialize(storage, in: NSRange(location: 0, length: 2)), "**A***B*")
    }
}
