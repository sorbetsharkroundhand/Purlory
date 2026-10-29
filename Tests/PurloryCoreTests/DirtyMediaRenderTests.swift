@testable import PurloryDocumentEngine
import AppKit
import XCTest
@testable import PurloryCore

@MainActor
final class DirtyMediaRenderTests: XCTestCase {
    func testOrdinaryEditAndCursorRefreshDoNotWalkOffscreenParagraphs() {
        let view = makeEditor()
        view.load(markdown: (0..<1_000).map { $0 % 20 == 0 ? "$$x_\($0)^2$$" : "한글 paragraph \($0)." }.joined(separator: "\n"))
        XCTAssertGreaterThan(view.lastMediaRenderParagraphCount, 900, "Explicit load remains a full construction")
        view.setSelectedRange(NSRange(location: 15, length: 0))
        view.insertText("글", replacementRange: NSRange(location: 15, length: 0))
        XCTAssertLessThan(view.lastMediaRenderParagraphCount, 20, "Ordinary dirty refresh walked the whole manuscript")
        view.setSelectedRange(NSRange(location: 40, length: 0))
        view.refreshRenderedBlocks()
        XCTAssertLessThan(view.lastMediaRenderParagraphCount, 20)
        XCTAssertFalse(view.mathRenders.isEmpty)
    }

    func testRawInlineMathAtDistantDirtyScopeFoldsWithoutScanningUnrelatedText() {
        let view = makeEditor()
        view.load(markdown: (0..<1_000).map { "Paragraph \($0)." }.joined(separator: "\n"))
        view.textStorage?.replaceCharacters(in: NSRange(location: (view.string as NSString).length, length: 0), with: " 값 $y^2$임")
        view.refreshRenderedBlocks()
        XCTAssertLessThan(view.lastMediaRenderParagraphCount, 20)
        XCTAssertTrue(view.serialize().hasSuffix("값 $y^2$임"))
        XCTAssertEqual(view.string.filter { $0 == "\u{FFFC}" }.count, 1)
    }

    func testDirtyGroupDissolutionRestoresProseAndKeepsUntouchedMedia() {
        let view = makeEditor()
        view.load(markdown: "$$\na+b\nc+d\n$$\nTail\n$$z^2$$")
        let first = (view.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        view.textStorage?.addAttribute(.purloryBlock, value: PurloryBlock.p.rawValue, range: first)
        view.refreshRenderedBlocks()
        let color = view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(color, .clear)
        let restored = view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(restored?.alignment, .natural, "Group cleanup must restore the prose style")
        let remaining = view.textStorage?.attribute(.paragraphStyle, at: first.upperBound, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(remaining?.minimumLineHeight ?? 0, 0, "Cleanup cannot erase newly rendered single-math height")
        XCTAssertTrue(view.mathRenders.contains { $0.range.location > first.upperBound })
        XCTAssertTrue(view.serialize().contains("z^2"))
    }

    func testSparseMathQueriesCannotJoinGroupsAcrossUnrelatedParagraphs() {
        let groups = BlockTextView.mathGroupRanges([
            (range: NSRange(location: 0, length: 3), block: .math, open: true, close: false),
            (range: NSRange(location: 3, length: 3), block: .math, open: false, close: false),
            (range: NSRange(location: 100, length: 3), block: .math, open: true, close: false),
            (range: NSRange(location: 103, length: 3), block: .math, open: false, close: true)],
            requireContiguousRanges: true)
        XCTAssertEqual(groups, [NSRange(location: 0, length: 6), NSRange(location: 100, length: 6)])
    }

    func testGroupDissolutionRetainsStoredParagraphPreferences() {
        let view = makeEditor()
        view.load(markdown: "$$\na+b\nc+d\n$$\nTail")
        let first = (view.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        view.textStorage?.addAttributes([.purloryBlock: PurloryBlock.p.rawValue,
            .purloryAlign: "right", .purloryLineSpacing: 17.0], range: first)
        view.refreshRenderedBlocks()
        let style = view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .right)
        XCTAssertEqual(style?.lineSpacing, 17)
        XCTAssertEqual(style?.minimumLineHeight, 0)
    }

    func testGlobalRestylePreservesFocusedMathEditingAndSelection() {
        let view = makeEditor()
        view.load(markdown: "$$x^2$$\nTail")
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.makeFirstResponder(view)
        let selection = NSRange(location: 1, length: 0)
        view.setSelectedRange(selection)
        view.refreshRenderedBlocks()
        XCTAssertTrue(view.mathRenders.isEmpty)
        view.restyleAll()
        XCTAssertTrue(view.mathRenders.isEmpty, "A full style refresh must retain source editing")
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(window.firstResponder === view)
    }

    private func makeEditor() -> BlockTextView {
        let view = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.textStorage?.delegate = view
        return view
    }
}
