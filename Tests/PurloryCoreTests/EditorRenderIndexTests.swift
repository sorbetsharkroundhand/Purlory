@testable import PurloryDocumentEngine
import AppKit
import XCTest
@testable import PurloryCore

@MainActor
final class EditorRenderIndexTests: XCTestCase {
    func testOrdinaryCharacterAndBlockAttributeEditsUpdateLocalParagraphs() throws {
        let view = makeEditor()
        view.load(markdown: (0..<2_000).map { "한글🙂 paragraph \($0)." }.joined(separator: "\n"))
        assertMatchesStorage(view)
        let builds = view.mediaIndexBuildCount
        _ = view.takeMediaDirtyRanges()
        view.textStorage?.replaceCharacters(in: NSRange(location: 2, length: 0), with: "\n새 줄")
        XCTAssertLessThan(view.lastMediaIndexUpdateParagraphs, 8)
        XCTAssertEqual(view.mediaIndexBuildCount, builds)
        assertMatchesStorage(view)
        XCTAssertLessThan(view.takeMediaDirtyRanges().reduce(0) { $0 + $1.length }, 200)
        let first = (view.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        view.textStorage?.addAttributes([.purloryBlock: PurloryBlock.math.rawValue, .purloryMathDelim: "open"], range: first)
        XCTAssertEqual(view.indexedMediaParagraphs(in: first).first?.record.block, .math)
        XCTAssertTrue(view.indexedMediaParagraphs(in: first).first?.record.open == true)
        XCTAssertEqual(view.mediaIndexBuildCount, builds)
        XCTAssertLessThan(view.lastMediaIndexUpdateParagraphs, 8)
    }

    func testBatchedMergeDeleteMoveAndReloadCannotKeepOldLocations() {
        let view = makeEditor()
        view.load(markdown: "First\n$$x^2$$\nMiddle\nLast")
        assertMatchesStorage(view)
        let storage = view.textStorage!
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 6), with: "")
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\nFirst")
        storage.endEditing()
        assertMatchesStorage(view)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "Changed\n🙂")
        assertMatchesStorage(view)
        view.load(markdown: "# Other document\n$$\na+b\nc+d\n$$\nTail")
        assertMatchesStorage(view)
        let paragraphs = view.indexedMediaParagraphs(in: NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertTrue(paragraphs.contains { $0.record.open })
        XCTAssertTrue(paragraphs.contains { $0.record.close })
    }

    func testUndoRedoUpdatesIndexOnTheNativeStorageDelegatePath() {
        let view = makeEditor(), window = RenderIndexUndoWindow()
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.testUndo.removeAllActions(); window.contentView = nil; window.close() }
        view.allowsUndo = true
        view.load(markdown: "First\nSecond")
        assertMatchesStorage(view)
        window.testUndo.beginUndoGrouping()
        view.insertText("새 줄\n", replacementRange: NSRange(location: 0, length: 0))
        window.testUndo.endUndoGrouping()
        assertMatchesStorage(view)
        let edited = view.string
        window.testUndo.undo()
        assertMatchesStorage(view)
        XCTAssertEqual(view.string, "First\nSecond")
        window.testUndo.redo()
        assertMatchesStorage(view)
        XCTAssertEqual(view.string, edited)
    }

    private func assertMatchesStorage(_ view: BlockTextView, file: StaticString = #filePath, line: UInt = #line) {
        let ns = view.string as NSString
        let indexed = view.indexedMediaParagraphs(in: NSRange(location: 0, length: ns.length))
        var expected: [NSRange] = [], location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            expected.append(range); location = range.upperBound
        }
        XCTAssertEqual(indexed.map(\.range), expected, file: file, line: line)
        for paragraph in indexed {
            let attrs = view.textStorage!.attributes(at: paragraph.range.location, effectiveRange: nil)
            XCTAssertEqual(paragraph.record.block.rawValue, attrs[.purloryBlock] as? String ?? "p", file: file, line: line)
        }
    }
    private func makeEditor() -> BlockTextView {
        let view = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.textStorage?.delegate = view
        return view
    }
}

@MainActor
private final class RenderIndexUndoWindow: NSWindow {
    let testUndo = UndoManager()
    override var undoManager: UndoManager? { testUndo }
}
