@testable import PurloryIntelligence
@testable import PurloryInference
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class GhostAcceptanceUndoTests: XCTestCase {
    func testTabAcceptanceUndoPreservesTheLastTypedHangulCharacter() async throws {
        try await verifyAcceptance(keyCode: 48, characters: "\t", accepted: " 아무도 없었다.")
    }

    func testRightArrowAcceptanceUndoPreservesTheLastTypedHangulCharacter() async throws {
        try await verifyAcceptance(keyCode: 124, characters: "\u{F703}", accepted: " 아무도")
    }

    private func verifyAcceptance(keyCode: UInt16, characters: String, accepted: String) async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("도경은 문을 열었다. 방 안에")
        let editor = try await h.editor()
        h.window.makeKeyAndOrderFront(nil)
        h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("는", replacementRange: editor.selectedRange())
        // Real typing and accepting a generated suggestion occur in separate events.
        try await Task.sleep(for: .milliseconds(30))
        let before = "도경은 문을 열었다. 방 안에는"
        XCTAssertEqual(editor.serialize(), before)
        h.completion.publishCompletion(.init(text: " 아무도 없었다.", timeToFirstChunk: nil,
            totalTime: 0, promptTokensPerSecond: nil, generationTokensPerSecond: nil,
            stoppedAtSentenceBoundary: true, promptTokenCount: 0, reusedPromptTokens: 0),
            caretLocation: editor.selectedRange().location, mode: "fast")
        XCTAssertEqual(editor.ghostText, " 아무도 없었다.")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
        editor.keyDown(with: event)
        await h.layout()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(editor.serialize(), before + accepted)
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, before + accepted)
        editor.insertText("x", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(30))
        editor.undo(nil)
        await h.layout()
        XCTAssertEqual(editor.serialize(), before + accepted, "Typing after acceptance is a separate undo unit")
        editor.undo(nil)
        await h.layout()
        XCTAssertEqual(editor.serialize(), before, "Undoing Ghost must preserve the author's previous input")
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, before)
    }
}
