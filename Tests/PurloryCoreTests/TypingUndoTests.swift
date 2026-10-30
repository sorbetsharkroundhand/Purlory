@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class TypingUndoTests: XCTestCase {
    func testResponderUndoAndRedoUseTheActiveDocumentHistory() async throws {
        let h = try await SourceNavigationHarness(); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        h.window.makeKeyAndOrderFront(nil); h.window.makeFirstResponder(view)
        manager.removeAllActions(); manager.groupsByEvent = true
        type("Earlier recent", into: view, manager: manager)
        XCTAssertTrue(manager.canUndo)
        XCTAssertTrue(view.tryToPerform(Selector(("undo:")), with: nil))
        XCTAssertEqual(view.serialize(), "Earlier ")
        XCTAssertTrue(view.tryToPerform(Selector(("redo:")), with: nil))
        XCTAssertEqual(view.serialize(), "Earlier recent")
    }
    func testContinuousTypingKeepsEarlierWordsWhenUndoingLastWord() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("")
        let view = try await h.editor()
        let manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        manager.removeAllActions()
        type("First sentence. Second sentence.", into: view, manager: manager)
        await h.layout()
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, "First sentence. Second sentence.")
        manager.undo()
        XCTAssertEqual(view.serialize(), "First sentence. Second ")
        manager.redo()
        XCTAssertEqual(view.serialize(), "First sentence. Second sentence.")
    }

    func testCaretMovementSeparatesEditsAndRedoRestoresSelection() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("Original manuscript. ")
        let view = try await h.editor()
        let manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type("tail", into: view, manager: manager)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("head", into: view, manager: manager)
        manager.undo()
        XCTAssertEqual(view.serialize(), "Original manuscript. tail")
        manager.redo()
        XCTAssertEqual(view.serialize(), "headOriginal manuscript. tail")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testPauseStartsNewTypingBurstWithoutSavingOrMovingCaret() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        type("earlier", into: view, manager: manager, startingAt: 100)
        type("recent", into: view, manager: manager, startingAt: 110)
        manager.undo()
        XCTAssertEqual(view.serialize(), "earlier")
        manager.redo()
        XCTAssertEqual(view.serialize(), "earlierrecent")
    }

    func testNewParagraphDoesNotUndoPreviousParagraph() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        type("Earlier\nRecent", into: view, manager: manager)
        XCTAssertEqual(view.serialize(), "Earlier\nRecent")
        manager.undo()
        XCTAssertEqual(view.serialize(), "Earlier\n")
        manager.redo()
        XCTAssertEqual(view.serialize(), "Earlier\nRecent")
    }

    func testSaveDoesNotSplitTypingAndTerminationPersistsUndoRedo() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        type("ear", into: view, manager: manager, startingAt: 100)
        try await h.fixture.session.flush()
        type("lier", into: view, manager: manager, startingAt: 100.03)
        manager.undo()
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, "")
        try await h.fixture.session.flush()
        let undone = try await h.fixture.store.load(id: h.fixture.project.id)
        XCTAssertEqual(undone.documents[0].body, "")
        manager.redo()
        XCTAssertEqual(view.serialize(), "earlier")
        try await h.fixture.session.flushForTermination()
        let reopened = ProjectSession(store: h.fixture.store, defaults: h.fixture.defaults)
        try await reopened.bootstrap()
        XCTAssertEqual(reopened.selectedDocument?.body, "earlier")
    }

    func testTypingUndoAndRedoCannotCrossDocumentSwitches() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        let session = h.fixture.session, a = try XCTUnwrap(session.selectedDocumentID)
        session.updateSelectedDocumentBody("")
        var view = try await h.editor()
        let manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        type("Alpha one", into: view, manager: manager)
        let b = try XCTUnwrap(session.createDocument(title: "B"))
        view = try await h.editor()
        let other = try XCTUnwrap(view.undoManager)
        other.groupsByEvent = true
        XCTAssertFalse(other === manager)
        XCTAssertFalse(other.canUndo)
        XCTAssertTrue(manager.canUndo, "The retained A editor keeps its own history")
        type("Beta two", into: view, manager: other)
        other.undo()
        XCTAssertEqual(view.serialize(), "Beta ")
        XCTAssertTrue(other.canRedo)
        session.selectDocument(a)
        view = try await h.editor()
        XCTAssertEqual(view.serialize(), "Alpha one")
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        XCTAssertTrue(view.undoManager === manager)
        session.selectDocument(b)
        view = try await h.editor()
        XCTAssertEqual(view.serialize(), "Beta ")
        XCTAssertTrue(view.undoManager === other)
        XCTAssertTrue(other.canUndo)
        XCTAssertTrue(other.canRedo)
    }

    func testLongManuscriptSurvivesUndoOfRecentWord() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        let manuscript = String(repeating: "An earlier paragraph remains intact.\n", count: 1000)
        h.fixture.session.updateSelectedDocumentBody(manuscript)
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type("New words", into: view, manager: manager)
        manager.undo()
        XCTAssertEqual(view.serialize(), manuscript + "New ")
        manager.redo()
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, manuscript + "New words")
    }

    func testMarkedHangulCommitsAsOneUndoableSyllableAfterWordBoundary() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        type("Earlier ", into: view, manager: manager)
        for marked in ["ㅎ", "하", "한"] {
            view.setMarkedText(marked, selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            drainEvent(manager)
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.string, "Earlier " + marked)
        }
        view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
        drainEvent(manager)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.serialize(), "Earlier 한")
        manager.undo()
        XCTAssertEqual(view.serialize(), "Earlier ")
        manager.redo()
        XCTAssertEqual(view.serialize(), "Earlier 한")
    }

    private func type(_ text: String, into view: BlockTextView, manager: UndoManager,
                      startingAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Native typing coalescence requires the real groupsByEvent contract.
        for (offset, character) in text.enumerated() {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: startingAt + Double(offset) * 0.01, windowNumber: view.window!.windowNumber,
                context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                isARepeat: false, keyCode: character == "\n" ? 36 : 0)!
            view.keyDown(with: event)
            drainEvent(manager)
        }
    }

    private func drainEvent(_ manager: UndoManager) {
        let deadline = Date().addingTimeInterval(1)
        while manager.groupingLevel > 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        XCTAssertEqual(manager.groupingLevel, 0)
    }
}
