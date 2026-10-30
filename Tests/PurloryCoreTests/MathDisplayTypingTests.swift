@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class MathDisplayTypingTests: XCTestCase {
    func testTypedDoubleDollarFormulaStaysSourceUntilItBecomesADisplayBlock() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        view.window?.makeFirstResponder(view)
        manager.beginUndoGrouping()
        for character in "$$E=mc^2$" {
            view.insertText(String(character), replacementRange: view.selectedRange())
        }
        XCTAssertEqual(view.string, "$$E=mc^2$", "Incomplete display source must not become an inline attachment")
        view.insertText("$", replacementRange: view.selectedRange())
        manager.endUndoGrouping()
        XCTAssertEqual(view.string, "E=mc^2")
        XCTAssertEqual(view.blockInfo(in: NSRange(location: 0, length: view.string.utf16.count)).block, .math)
        XCTAssertEqual(view.serialize(), "$$E=mc^2$$")
        manager.undo()
        XCTAssertEqual(view.serialize(), "")
        manager.redo()
        XCTAssertEqual(view.string, "E=mc^2")
        XCTAssertEqual(view.serialize(), "$$E=mc^2$$")
    }

    func testMarkedDisplaySourceIsNotConsumedBeforeCommit() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        view.window?.makeFirstResponder(view)
        // The harness disables event groups; model one native input event.
        manager.beginUndoGrouping()
        defer { manager.endUndoGrouping() }
        let marked = "$$한글$"
        view.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.string, marked)
        view.insertText("$$한글$$", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string, "한글")
        XCTAssertEqual(view.serialize(), "$$한글$$")
    }
}
