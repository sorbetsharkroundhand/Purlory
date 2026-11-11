import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryDocumentEngine
@testable import PurloryWorkspaceUI

@MainActor
final class EditorParagraphMoveRegressionTests: XCTestCase {

    private func makeEditor(markdown: String, sourceMode: Bool = false) -> (NSScrollView, BlockTextView, UndoManager) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let tv = BlockTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let undo = UndoManager()
        undo.groupsByEvent = false
        tv.documentUndoManager = undo
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        scroll.documentView = tv
        tv.load(markdown: markdown, sourceMode: sourceMode)
        undo.removeAllActions()
        return (scroll, tv, undo)
    }

    // MARK: - F04: Paragraph move across code blocks, math groups, Undo/Redo, source mode

    func testF04MoveParagraphAfterCodeBlockDoesNotCorruptCodeFenceAndSupportsUndoRedo() {
        let initial = """
        ```swift
        let x = 1
        ```
        first
        second
        """
        let (_, tv, undo) = makeEditor(markdown: initial)

        // Place caret in "first"
        let ns = tv.string as NSString
        let firstRange = ns.range(of: "first")
        XCTAssertNotEqual(firstRange.location, NSNotFound)
        tv.setSelectedRange(NSRange(location: firstRange.location + 2, length: 0))

        // Move "first" down below "second"
        tv.moveCurrentParagraph(direction: 1)

        let expectedAfterMove = """
        ```swift
        let x = 1
        ```
        second
        first
        """
        XCTAssertEqual(tv.serialize(), expectedAfterMove)
        XCTAssertFalse(tv.isSourceMode)

        // Undo should restore initial markdown and caret inside "first"
        undo.undo()
        XCTAssertEqual(tv.serialize(), initial)
        XCTAssertEqual(tv.selectedRange().location, firstRange.location + 2)

        // Redo should reapply the move
        undo.redo()
        XCTAssertEqual(tv.serialize(), expectedAfterMove)
    }

    func testF04MoveParagraphUpAcrossCodeBlockAndMultilineMathBlock() {
        let initial = """
        ```python
        print("a")
        print("b")
        ```
        $$
        a + b = c
        d + e = f
        $$
        after math
        """
        let (_, tv, undo) = makeEditor(markdown: initial)
        let ns = tv.string as NSString
        let afterMathRange = ns.range(of: "after math")
        XCTAssertNotEqual(afterMathRange.location, NSNotFound)
        tv.setSelectedRange(NSRange(location: afterMathRange.location, length: 0))

        // Move "after math" up once -> should jump above the entire multiline math block
        tv.moveCurrentParagraph(direction: -1)
        let expected1 = """
        ```python
        print("a")
        print("b")
        ```
        after math
        $$
        a + b = c
        d + e = f
        $$
        """
        XCTAssertEqual(tv.serialize(), expected1)

        // Move "after math" up again -> should jump above the entire multi-line code block
        tv.moveCurrentParagraph(direction: -1)
        let expected2 = """
        after math
        ```python
        print("a")
        print("b")
        ```
        $$
        a + b = c
        d + e = f
        $$
        """
        XCTAssertEqual(tv.serialize(), expected2)

        undo.undo()
        XCTAssertEqual(tv.serialize(), expected1)
        undo.undo()
        XCTAssertEqual(tv.serialize(), initial)
    }

    func testF04MoveParagraphInSourceModePreservesSourceModeAndMovesFencedBlockAsUnit() {
        let initial = """
        ```
        code line
        ```
        alpha
        beta
        """
        let (_, tv, undo) = makeEditor(markdown: initial, sourceMode: true)
        XCTAssertTrue(tv.isSourceMode)

        let ns = tv.string as NSString
        let alphaRange = ns.range(of: "alpha")
        tv.setSelectedRange(NSRange(location: alphaRange.location, length: 0))

        tv.moveCurrentParagraph(direction: 1)
        XCTAssertTrue(tv.isSourceMode, "Source mode must be preserved after moving paragraph")
        XCTAssertEqual(
            tv.serialize(),
            """
            ```
            code line
            ```
            beta
            alpha
            """
        )

        undo.undo()
        XCTAssertTrue(tv.isSourceMode)
        XCTAssertEqual(tv.serialize(), initial)
    }

    // MARK: - H1: Source mode toggle Undo safety

    func testH1SourceModeToggleRegistersAtomicUndoWithoutCorruptingPriorEdits() {
        let initial = "# 제목\n첫 문단"
        let (_, tv, undo) = makeEditor(markdown: initial, sourceMode: false)

        // Perform an edit in block mode
        let endLoc = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: endLoc, length: 0))
        undo.beginUndoGrouping()
        tv.insertText(" 추가", replacementRange: tv.selectedRange())
        undo.endUndoGrouping()
        XCTAssertEqual(tv.serialize(), "# 제목\n첫 문단 추가")

        // Toggle source mode ON
        tv.setSourceMode(true)
        XCTAssertTrue(tv.isSourceMode)
        XCTAssertEqual(tv.string, "# 제목\n첫 문단 추가")

        // Undo 1: reverts source mode transition back to block mode
        undo.undo()
        XCTAssertFalse(tv.isSourceMode)
        XCTAssertEqual(tv.serialize(), "# 제목\n첫 문단 추가")

        // Undo 2: cleanly reverts the block-mode typing edit without range mismatch
        undo.undo()
        XCTAssertFalse(tv.isSourceMode)
        XCTAssertEqual(tv.serialize(), initial)

        // Redo 1 & Redo 2
        undo.redo()
        XCTAssertEqual(tv.serialize(), "# 제목\n첫 문단 추가")
        undo.redo()
        XCTAssertTrue(tv.isSourceMode)
        XCTAssertEqual(tv.serialize(), "# 제목\n첫 문단 추가")
    }
}
