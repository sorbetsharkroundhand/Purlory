import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryDocumentEngine
@testable import PurloryIntelligence
@testable import PurloryWorkspaceUI

final class P0SafetyHardeningTests: XCTestCase {

    @MainActor
    private func makeHostedEditor(markdown: String) -> (NSWindow, NSScrollView, BlockTextView) {
        let storage = NSTextStorage()
        let layoutManager = PurloryLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        editor.isEditable = true
        editor.allowsUndo = true
        editor.load(markdown: markdown)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = editor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(editor)
        return (window, scrollView, editor)
    }

    // MARK: - Cluster 1: Editor Correctness, Teardown Leaks & Codec Safety

    @MainActor
    func testObjectKeyActionUsesDownArrowNotF1() {
        let downArrow = String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)
        let f1Key = String(UnicodeScalar(NSEvent.SpecialKey.f1.rawValue)!)

        XCTAssertEqual(BlockTextView.objectKeyAction(downArrow, command: false, option: false), .exitAfter)
        XCTAssertEqual(BlockTextView.objectKeyAction(downArrow, command: false, option: true), .move(1))
        XCTAssertNil(BlockTextView.objectKeyAction(f1Key, command: false, option: false))
        XCTAssertNil(BlockTextView.objectKeyAction(f1Key, command: false, option: true))
    }

    @MainActor
    func testHandleMathEditingKeyMovesDownWithDownArrowNotF1() throws {
        let (window, _, editor) = makeHostedEditor(markdown: "$$E=mc^2$$\n본문 줄")
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        let f1 = String(UnicodeScalar(NSEvent.SpecialKey.f1.rawValue)!)
        let f1Event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: f1,
            charactersIgnoringModifiers: f1,
            isARepeat: false,
            keyCode: 122
        ))
        XCTAssertFalse(editor.handleMathEditingKey(f1Event), "F1 must not trigger math move")
        XCTAssertEqual(editor.serialize(), "$$E=mc^2$$\n본문 줄")

        let down = String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)
        let downEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: down,
            charactersIgnoringModifiers: down,
            isARepeat: false,
            keyCode: 125
        ))
        XCTAssertTrue(editor.handleMathEditingKey(downEvent), "Option+DownArrow must move math paragraph down")
        XCTAssertEqual(editor.serialize(), "본문 줄\n$$E=mc^2$$")
    }

    @MainActor
    func testMoveMathParagraphDoesNotSelectImageAndPreservesAttributesAndLastLineUp() {
        let (window, _, editor) = makeHostedEditor(markdown: "앞문단\n$$E=mc^2$$")
        defer { window.close() }

        final class SpyDelegate: NSObject, NSTextViewDelegate {
            var didChangeCount = 0
            func textDidChange(_ notification: Notification) { didChangeCount += 1 }
        }
        let spy = SpyDelegate()
        editor.delegate = spy

        let ns = editor.string as NSString
        let lastPara = ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0))
        editor.moveMathParagraph(lastPara, offset: -1)

        XCTAssertNil(editor.selectedImageLocation, "Moving a math paragraph must not set selectedImageLocation")
        XCTAssertEqual(editor.serialize(), "$$E=mc^2$$\n앞문단")
        XCTAssertGreaterThan(spy.didChangeCount, 0, "Moving a math paragraph must notify textDidChange")
        let movedPara = (editor.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.blockInfo(in: movedPara).block, .math)
        XCTAssertEqual(editor.undoManager?.undoActionName, "수식 이동")

        editor.undoManager?.undo()
        XCTAssertEqual(editor.serialize(), "앞문단\n$$E=mc^2$$")
    }

    @MainActor
    func testMoveImageParagraphUsesUTF16OffsetWithEmojiNeighbor() {
        let (window, _, editor) = makeHostedEditor(markdown: "![사진](images/a.png)\n앞😀😀문단")
        defer { window.close() }

        let ns = editor.string as NSString
        let imagePara = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        editor.selectedImageLocation = imagePara.location
        editor.moveImageParagraph(imagePara, offset: 1)

        XCTAssertEqual(editor.serialize(), "앞😀😀문단\n![사진](images/a.png)")
        let expectedUTF16 = ("앞😀😀문단\n" as NSString).length
        XCTAssertEqual(editor.selectedImageLocation, expectedUTF16)
    }

    @MainActor
    func testDragMoveMultiLineMathGroupPreservesAttributesAndSupportsUndo() throws {
        let markdown = "첫문단\n$$\na + b\n$$\n끝문단"
        let (window, _, editor) = makeHostedEditor(markdown: markdown)
        defer { window.close() }
        let container = try XCTUnwrap(editor.textContainer)
        editor.layoutManager?.ensureLayout(for: container)

        let ns = editor.string as NSString
        let mathOpenRange = ns.range(of: "$$")
        XCTAssertNotEqual(mathOpenRange.location, NSNotFound)

        // Move the multi-line math group before the first paragraph (top of view).
        editor.moveParagraph(at: mathOpenRange.location, as: .math, toViewPoint: NSPoint(x: 10, y: 2))

        XCTAssertEqual(editor.serialize(), "$$\na + b\n$$\n첫문단\n끝문단")
        let newNS = editor.string as NSString
        let openPara = newNS.paragraphRange(for: NSRange(location: 0, length: 0))
        let bodyPara = newNS.paragraphRange(for: NSRange(location: openPara.upperBound, length: 0))
        let closePara = newNS.paragraphRange(for: NSRange(location: bodyPara.upperBound, length: 0))
        XCTAssertEqual(editor.blockInfo(in: openPara).block, .math)
        XCTAssertEqual(editor.blockInfo(in: bodyPara).block, .math)
        XCTAssertEqual(editor.blockInfo(in: closePara).block, .math)
        XCTAssertEqual(editor.storageMathDelim(at: openPara.location), "open")
        XCTAssertEqual(editor.storageMathDelim(at: closePara.location), "close")

        editor.undoManager?.undo()
        XCTAssertEqual(editor.serialize(), markdown)
    }

    @MainActor
    func testCaretBlinkTimerInvalidatedOnWindowDetach() {
        let (window, scrollView, editor) = makeHostedEditor(markdown: "테스트")
        defer { window.close() }

        editor.restartCaretBlink()
        let timer = editor.caretBlinkTimer
        XCTAssertNotNil(timer)
        XCTAssertTrue(timer?.isValid == true)

        scrollView.removeFromSuperview()
        XCTAssertNil(editor.caretBlinkTimer)
        XCTAssertFalse(timer?.isValid == true)
    }
}

private extension BlockTextView {
    func storageMathDelim(at location: Int) -> String? {
        guard let storage = textStorage, location < storage.length else { return nil }
        return storage.attribute(.purloryMathDelim, at: location, effectiveRange: nil) as? String
    }
}
