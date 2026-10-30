@testable import PurloryIntelligence
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class MathEditGeometryTests: XCTestCase {
    func testSingleLineMathUsesOneEditingRegionAndActualGlyphCaret() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("$$E=mc^2$$\nAfter")
        let view = try await h.editor()
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.refreshRenderedBlocks()
        let rendered = try XCTUnwrap(view.mathDrawnRect(forParagraphAt: 0))
        // Reproduce a busy main actor delaying the scheduled preview's start.
        let schedulerLoad = Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
            while ContinuousClock.now < deadline {}
        }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.refreshRenderedBlocks()
        view.refreshActiveLineHighlight()
        let preview = try await waitForMathPreview(in: view)
        await schedulerLoad.value
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let para = (view.string as NSString).paragraphRange(for: view.selectedRange())
        let glyphs = manager.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
        let block = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertGreaterThanOrEqual(preview.frame.minY, block.minY)
        XCTAssertLessThanOrEqual(preview.frame.maxY, block.maxY, "Preview must belong to the active math block")
        let caret = try XCTUnwrap(view.subviews.first {
            $0.layer?.cornerRadius == 1 && $0.frame.width == 2 && !$0.isHidden
        })
        let index = manager.glyphIndexForCharacter(at: view.selectedRange().location)
        let fragment = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
        let baseline = fragment.minY + manager.location(forGlyphAt: index).y + view.textContainerOrigin.y
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(caret.frame.maxY, baseline - font.descender, accuracy: 1,
                       "Caret must follow the source glyph baseline, including enlarged math line height")
        XCTAssertNil(view.mathDrawnRect(forParagraphAt: 0))
        XCTAssertEqual(view.serialize(), "$$E=mc^2$$\nAfter")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.refreshRenderedBlocks()
        XCTAssertEqual(view.mathDrawnRect(forParagraphAt: 0), rendered, "Mode changes must not move the rendered math")
        XCTAssertNil(preview.superview)
    }

    func testMathAndProseEditingKeepPersistentHighlightHidden() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("$$E=mc^2$$\nAfter")
        let view = try await h.editor()
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.refreshActiveLineHighlight()
        let band = try XCTUnwrap(view.subviews.first { $0.layer?.cornerRadius == 6 })
        XCTAssertTrue(band.isHidden)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.refreshActiveLineHighlight()
        XCTAssertTrue(band.isHidden)
    }

    func testMultilinePreviewStaysBesideTheWholeGroupAndPreservesSelection() async throws {
        let markdown = "$$\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n$$\nAfter"
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        // This is the wide, side-by-side preview contract. A tiled document may
        // intentionally omit a preview when it would cover the source glyphs.
        if let active = h.fixture.session.selectedDocumentID, let model = h.requests.spatialWorkspace {
            for id in model.layout.openDocuments where id != active { _ = model.close(.document(id)) }
        }
        h.fixture.session.updateSelectedDocumentBody(markdown)
        let view = try await h.editor()
        view.window?.makeFirstResponder(view)
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.refreshRenderedBlocks()
        let rendered = try XCTUnwrap(view.mathDrawnRect(forParagraphAt: 0))
        let group = try XCTUnwrap(view.mathGroup(containing: 0))
        let selection = NSRange(location: (view.string as NSString).range(of: "a &").location, length: 2)
        view.setSelectedRange(selection)
        view.refreshRenderedBlocks()
        let preview = try await waitForMathPreview(in: view)
        let lm = try XCTUnwrap(view.layoutManager), tc = try XCTUnwrap(view.textContainer)
        let block = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: group, actualCharacterRange: nil), in: tc)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertGreaterThanOrEqual(preview.frame.minY, block.minY)
        XCTAssertLessThanOrEqual(preview.frame.maxY, block.maxY)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.serialize(), markdown)
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.refreshRenderedBlocks()
        XCTAssertEqual(view.mathDrawnRect(forParagraphAt: 0), rendered)
        XCTAssertNil(preview.superview)
    }

    func testNarrowMathSourceKeepsItsOriginalWhenNoPreviewFits() async throws {
        let h = try await SourceNavigationHarness(); defer { h.close() }
        let original = "$$\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n$$\nAfter"
        h.fixture.session.updateSelectedDocumentBody(original)
        let editor = try await h.editor(); editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange((editor.string as NSString).range(of: "a &"))
        editor.refreshRenderedBlocks()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(editor.serialize(), original)
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), "a &")
        if let preview = editor.subviews.first(where: { $0 is NSHostingView<MathPreviewView> }) {
            XCTAssertLessThanOrEqual(preview.frame.maxX, editor.bounds.maxX)
        }
    }

    func testTallAndInvalidMathKeepNativeLayoutAcrossEditingModes() async throws {
        for latex in ["\\frac{1}{2}", "\\frac{1{"] {
            let h = try await SourceNavigationHarness()
            defer { h.close() }
            h.fixture.session.updateSelectedDocumentBody("$$\(latex)$$\nAfter")
            let view = try await h.editor()
            view.window?.makeFirstResponder(view)
            let end = (view.string as NSString).length
            view.setSelectedRange(NSRange(location: end, length: 0))
            view.refreshRenderedBlocks()
            let before = try XCTUnwrap(view.mathDrawnRect(forParagraphAt: 0))
            let beforeCaret = view.firstRect(forCharacterRange: NSRange(location: 2, length: 0), actualRange: nil)
            view.setSelectedRange(NSRange(location: 2, length: 0))
            view.refreshRenderedBlocks()
            let afterCaret = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
            XCTAssertEqual(beforeCaret.minY, afterCaret.minY, accuracy: 0.5)
            view.setSelectedRange(NSRange(location: end, length: 0))
            view.refreshRenderedBlocks()
            XCTAssertEqual(view.mathDrawnRect(forParagraphAt: 0), before)
        }
    }

    func testMathSourceEditUndoRedoAndCancelledPreviewPreserveManuscript() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("$$E=mc^2$$\nAfter")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        manager.beginUndoGrouping()
        view.insertText("x", replacementRange: view.selectedRange())
        manager.endUndoGrouping()
        XCTAssertEqual(view.serialize(), "$$E=xmc^2$$\nAfter")
        manager.undo()
        XCTAssertEqual(view.serialize(), "$$E=mc^2$$\nAfter")
        manager.redo()
        XCTAssertEqual(view.serialize(), "$$E=xmc^2$$\nAfter")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.refreshRenderedBlocks()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(view.subviews.contains { $0 is NSHostingView<MathPreviewView> })
    }

    private func waitForMathPreview(
        in view: BlockTextView, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> NSHostingView<MathPreviewView> {
        func preview() -> NSHostingView<MathPreviewView>? {
            view.subviews.compactMap { $0 as? NSHostingView<MathPreviewView> }.first
        }
        // The debounce starts when its main-actor task runs, which can be later
        // than the test's suspension. Wait for presentation, not elapsed time.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while preview() == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(preview(), "Math preview did not appear", file: file, line: line)
    }
}
