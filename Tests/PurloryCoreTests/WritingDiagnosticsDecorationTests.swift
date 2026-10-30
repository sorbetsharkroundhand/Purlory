@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class WritingDiagnosticsDecorationTests: XCTestCase {
    func testDecorationNeverMutatesStorageOrOtherLayers() throws {
        let harness = WritingEditorHarness("🙂 **됬다** 원고\n앞 $x$ 뒤")
        defer { harness.close() }
        let editor = harness.editor, range = (harness.body as NSString).range(of: "됬다")
        let finding = writingEditorFinding(harness, range: range)
        let native = try XCTUnwrap(editor.nativeRange(forSource: .init(range), revision: editor.writingNativeRevision))
        editor.setSelectedRange(.init(location: 0, length: 2))
        editor.ghostText = " 합성 제안"
        editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.yellow, forCharacterRange: native.nsRange)
        let storage = NSAttributedString(attributedString: try XCTUnwrap(editor.textStorage)), source = editor.serialize()
        let selection = editor.selectedRange(), ghost = editor.ghostText
        editor.setWritingDiagnostics([finding], revision: editor.writingNativeRevision)
        XCTAssertEqual(editor.writingDecorationRanges(visible: .init(location: 0, length: editor.string.utf16.count)), [native.nsRange])
        XCTAssertTrue(editor.textStorage!.isEqual(to: storage))
        XCTAssertEqual(editor.serialize(), source)
        XCTAssertEqual(editor.selectedRange(), selection); XCTAssertEqual(editor.ghostText, ghost)
        XCTAssertNotNil(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: native.location, effectiveRange: nil))
        editor.setWritingDiagnostics([], revision: editor.writingNativeRevision)
        XCTAssertTrue(editor.writingDecorationRanges(visible: native.nsRange).isEmpty)
        XCTAssertTrue(editor.textStorage!.isEqual(to: storage))
        XCTAssertEqual(editor.serialize(), source)
        XCTAssertNotNil(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: native.location, effectiveRange: nil))
    }

    func test300kDocumentDecorationVisitsOnlyVisibleSortedSpans() throws {
        let harness = WritingEditorHarness(String(repeating: "됬다 ", count: 100_000))
        defer { harness.close() }
        let base = writingEditorFinding(harness, range: .init(location: 0, length: 2))
        let findings = (0..<1000).map { index in
            let source = WritingDiagnosticRange(location: index * 300, length: 2)
            return WritingDiagnosticsFinding(id: "fixture-\(index)", diagnostic: base.diagnostic, sourceRanges: [source], relatedSourceRanges: [],
                evidence: .init(documentID: harness.key.documentID, quote: "됬다", utf16Hint: source.location), contextRange: source, stamp: base.stamp)
        }
        harness.editor.setWritingDiagnostics(findings, revision: harness.editor.writingNativeRevision)
        let start = Date.timeIntervalSinceReferenceDate
        for _ in 0..<1000 {
            XCTAssertEqual(harness.editor.writingDecorationRanges(visible: .init(location: 150_000, length: 450)).count, 2)
            XCTAssertLessThanOrEqual(harness.editor.writingDecorations.lastQueryVisits, 16)
        }
        let elapsed = (Date.timeIntervalSinceReferenceDate - start) * 1000
        print("Writing decoration lookup: 300000 UTF16, 1000 marks, 1000 visible queries: \(elapsed) ms; no paint/IME acceptance claim")
    }

    func testStyleStaleAndCompositionNeverGetMarks() throws {
        let harness = WritingEditorHarness("됬다 다른 문장")
        defer { harness.close() }
        let editor = harness.editor
        let style = writingEditorFinding(harness, range: .init(location: 0, length: 2), category: .style)
        editor.setWritingDiagnostics([style], revision: editor.writingNativeRevision)
        XCTAssertTrue(editor.writingDecorationRanges(visible: .init(location: 0, length: editor.string.utf16.count)).isEmpty)
        let finding = writingEditorFinding(harness, range: .init(location: 0, length: 2))
        editor.setWritingDiagnostics([finding], revision: editor.writingNativeRevision)
        harness.edit("밖 ", range: .init(location: 0, length: 0))
        XCTAssertTrue(editor.writingDecorationRanges(visible: .init(location: 0, length: editor.string.utf16.count)).isEmpty)
        editor.setWritingDiagnostics([finding], revision: editor.writingNativeRevision)
        XCTAssertTrue(editor.writingDecorationRanges(visible: .init(location: 0, length: editor.string.utf16.count)).isEmpty)
        let fresh = writingEditorFinding(harness, range: (harness.body as NSString).range(of: "됬다"))
        harness.window.testUndo.beginUndoGrouping()
        editor.setMarkedText("한", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 0, length: 0))
        editor.setWritingDiagnostics([fresh], revision: editor.writingNativeRevision)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(editor.writingDecorationRanges(visible: .init(location: 0, length: editor.string.utf16.count)).isEmpty)
        editor.unmarkText(); harness.window.testUndo.endUndoGrouping()
    }
}
