@_spi(Benchmark) @testable import PurloryInference
import AppKit
import Combine
import XCTest
@testable import PurloryCore

@MainActor
final class AskPurloryPanelTests: XCTestCase {
    func testExplicitDisabledMasterCannotAdmitAnswersEvenWithAReadyAuthorizedModel() {
        XCTAssertFalse(AskPurlorySupport.admits(ready: true, authorized: true, enabled: false, managing: false, pressure: false, modelID: "fixture"))
        XCTAssertTrue(AskPurlorySupport.admits(ready: true, authorized: true, enabled: true, managing: false, pressure: false, modelID: "fixture"))
    }
    private func search(_ panel: SourceSearchPanel) async {
        let ready = expectation(description: "Source search ready")
        let sub = panel.model.$hits.filter { !$0.isEmpty }.prefix(1).sink { _ in ready.fulfill() }
        panel.searchField.stringValue = "needle"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchField))
        await fulfillment(of: [ready], timeout: 2)
        withExtendedLifetime(sub) {}
    }
    private func line(_ packet: AskEvidencePacket) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["text": "**Answer** [S1]", "citations": [["source": "S1", "quote": packet.sources[0].hit.evidence.quote]]]), as: UTF8.self) + "\n"
    }

    func testNoModelKeepsSearchUsefulAndQuestionNeverStartsOnOpenOrSearch() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        _ = try await h.editor()
        let panel = try XCTUnwrap(SourceSearchPanel.present(session: h.fixture.session, requests: h.requests)); defer { panel.close() }
        await search(panel)
        XCTAssertFalse(panel.askButton.isEnabled); XCTAssertNil(panel.questionView)
        XCTAssertEqual(panel.resultTable.numberOfRows, 2)
        XCTAssertEqual(panel.askButton.accessibilityIdentifier(), "purlory.ask.open")
    }

    func testExplicitQuestionCitationsReturnToSameEditorWithoutMutationOrUndoLoss() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let editor = try await h.editor(), before = h.fixture.session.activeProject
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        let selection = editor.selectedRange(), undo = editor.undoManager?.canUndo
        var calls = 0
        h.requests.askSupport = AskPurlorySupport(available: true) { packet, _ in
            calls += 1; let line = try self.line(packet)
            return AskAnswerGeneration { emit in try emit(line) }
        }
        let panel = try XCTUnwrap(SourceSearchPanel.present(session: h.fixture.session, requests: h.requests)); defer { panel.close() }
        await search(panel); XCTAssertEqual(calls, 0)
        panel.askButton.performClick(nil)
        let question = try XCTUnwrap(panel.questionView)
        XCTAssertEqual(calls, 0); XCTAssertFalse(question.sendButton.isEnabled)
        XCTAssertEqual(question.questionField.accessibilityIdentifier(), "purlory.ask.question")
        let done = expectation(description: "Grounded answer complete")
        let sub = question.model.$status.filter { $0 == .complete }.prefix(1).sink { _ in done.fulfill() }
        question.questionField.stringValue = "Where is the needle?"
        question.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: question.questionField))
        question.sendButton.performClick(nil)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls, 1); XCTAssertEqual(question.model.blocks.count, 1)
        let packet = try XCTUnwrap(question.model.packet)
        XCTAssertTrue(question.answerView.activateSourceLink(AskAnswerView.sourceURL(packetID: packet.id, sourceID: "S1")))
        await h.layout()
        XCTAssertFalse(panel.window?.isVisible == true)
        XCTAssertTrue(h.requests.returnToWriting(in: h.fixture.session)); await h.layout()
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.undoManager?.canUndo, undo)
        XCTAssertEqual(h.fixture.session.activeProject, before)
        withExtendedLifetime(sub) {}
    }

    func testQuestionIMEAndBackKeepEditorAndPreparedSearch() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let editor = try await h.editor(), selection = editor.selectedRange()
        var calls = 0
        h.requests.askSupport = AskPurlorySupport(available: true) { _, _ in calls += 1; return AskAnswerGeneration { _ in } }
        let panel = try XCTUnwrap(SourceSearchPanel.present(session: h.fixture.session, requests: h.requests)); defer { panel.close() }
        await search(panel); panel.askButton.performClick(nil)
        let question = try XCTUnwrap(panel.questionView), composer = NSTextView()
        composer.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(question.control(question.questionField, textView: composer, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(composer.hasMarkedText()); XCTAssertEqual(calls, 0)
        question.backButton.performClick(nil)
        XCTAssertNil(panel.questionView); XCTAssertEqual(panel.model.hits.count, 2)
        XCTAssertEqual(editor.selectedRange(), selection)
    }

    func testCancelKeepsNativePartialButDocumentRetirementRemovesAllSourceActions() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        _ = try await h.editor()
        let started = expectation(description: "Native answer started"), cancelled = expectation(description: "Native answer cancelled")
        let pause = AskTestPause(started, cancelled: cancelled)
        var packet: AskEvidencePacket?
        h.requests.askSupport = AskPurlorySupport(available: true) { value, _ in
            packet = value; return AskAnswerGeneration { emit in await pause.run(emit: emit) }
        }
        let panel = try XCTUnwrap(SourceSearchPanel.present(session: h.fixture.session, requests: h.requests)); defer { panel.close() }
        await search(panel); panel.askButton.performClick(nil)
        let question = try XCTUnwrap(panel.questionView)
        question.questionField.stringValue = "Question"
        question.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: question.questionField))
        question.sendButton.performClick(nil)
        await fulfillment(of: [started], timeout: 2)
        let partial = expectation(description: "Native validated partial")
        let sub = question.model.$blocks.filter { $0.count == 1 }.prefix(1).sink { _ in partial.fulfill() }
        let original = try XCTUnwrap(packet)
        try await pause.send(line(original))
        await fulfillment(of: [partial], timeout: 2)
        question.answerView.textView.cancelOperation(nil)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(question.model.status, .cancelled); XCTAssertEqual(question.model.blocks.count, 1)
        XCTAssertTrue(question.answerView.textView.string.contains("Answer"))
        await pause.release()
        h.fixture.session.updateSelectedDocumentBody("Changed source")
        await h.layout()
        XCTAssertFalse(panel.window?.isVisible == true)
        XCTAssertFalse(question.answerView.activateSourceLink(AskAnswerView.sourceURL(packetID: original.id, sourceID: "S1")))
        XCTAssertTrue(question.answerView.textView.string.isEmpty)
        withExtendedLifetime(sub) {}
    }
}

@MainActor
final class AskAnswerViewTests: XCTestCase {
    private func blocks(_ packet: AskEvidencePacket, count: Int, long: Bool = false) throws -> [AskAnswerBlock] {
        var decoder = AskAnswerDecoder(packet: packet)
        for index in 0..<count {
            let text = long ? String(repeating: "Readable line \(index) with many narrow-column words. ", count: 28) : "**Bold** [outside](https://example.com)"
            let data = try JSONSerialization.data(withJSONObject: ["text": text, "citations": [["source": "S1", "quote": packet.sources[0].hit.evidence.quote]]])
            _ = try decoder.append(String(decoding: data, as: UTF8.self) + "\n")
        }
        return decoder.blocks
    }
    func testOnlyCurrentPacketSourcesBecomeAccessibleNavigationLinks() throws {
        _ = NSApplication.shared
        let packet = try AskTestFixture().packet(), view = AskAnswerView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        view.update(packet: packet, blocks: try blocks(packet, count: 1))
        XCTAssertFalse(view.textView.isEditable); XCTAssertTrue(view.textView.isSelectable)
        XCTAssertEqual(view.textView.accessibilityIdentifier(), "purlory.ask.answer")
        var links: [URL] = []
        view.textView.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.textView.string.utf16.count)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertFalse(links.isEmpty); XCTAssertTrue(links.allSatisfy { $0.scheme == "purlory-source" })
        var opened: String?
        view.onSource = { id, source in XCTAssertEqual(id, packet.id); opened = source }
        XCTAssertFalse(view.activateSourceLink(URL(string: "https://example.com")!))
        XCTAssertFalse(view.activateSourceLink(AskAnswerView.sourceURL(packetID: UUID(), sourceID: "S1")))
        XCTAssertTrue(view.activateSourceLink(AskAnswerView.sourceURL(packetID: packet.id, sourceID: "S1")))
        XCTAssertEqual(opened, "S1")
        opened = nil; view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        func key(_ code: UInt16, _ text: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        view.textView.keyDown(with: try key(48, "\t")); view.textView.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(opened, "S1", "Tab and Return must activate a packet source without a pointer")
        var cancelled = false; view.onCancel = { cancelled = true }
        view.textView.cancelOperation(nil)
        XCTAssertTrue(cancelled)
    }
    func testAppendPreservesSelectionAndUserScrollUntilBottomOwnershipReturns() throws {
        _ = NSApplication.shared
        let packet = try AskTestFixture().packet(), view = AskAnswerView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
        view.layoutSubtreeIfNeeded()
        view.update(packet: packet, blocks: try blocks(packet, count: 2, long: true))
        view.contentView.scroll(to: .zero); view.noteUserScroll()
        view.textView.setSelectedRange(NSRange(location: 0, length: 4))
        view.update(packet: packet, blocks: try blocks(packet, count: 3, long: true))
        XCTAssertEqual(view.contentView.bounds.minY, 0, accuracy: 1)
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 0, length: 4))
        let bottom = max(0, view.textView.frame.height - view.contentView.bounds.height)
        view.contentView.scroll(to: NSPoint(x: 0, y: bottom)); view.noteUserScroll()
        view.update(packet: packet, blocks: try blocks(packet, count: 4, long: true))
        XCTAssertGreaterThan(view.contentView.bounds.minY, bottom)
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 0, length: 4))
        view.contentView.scroll(to: .zero); view.noteUserScroll()
        window.setContentSize(NSSize(width: 240, height: 160)); view.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(view.textView.textContainer), manager = try XCTUnwrap(view.textView.layoutManager)
        manager.ensureLayout(for: container)
        XCTAssertGreaterThanOrEqual(view.textView.frame.height + 1, manager.usedRect(for: container).height + 16)
        XCTAssertEqual(view.contentView.bounds.minY, 0, accuracy: 1)
    }
}
