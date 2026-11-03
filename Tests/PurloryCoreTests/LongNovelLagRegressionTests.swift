@testable import PurloryIntelligence
@testable import PurloryStorage
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class LongNovelLagRegressionTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    private func makeEditor() -> BlockTextView {
        let storage = NSTextStorage()
        let layoutManager = PurloryLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = BlockTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 900), textContainer: container)
        storage.delegate = view
        view.allowsUndo = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        windows.append(window)
        return view
    }

    private func makeSyntheticNovel(paragraphPairs: Int = 3_300) -> String {
        var lines: [String] = ["# 합성 장편 소설", "저자: 테스트 작가", "출전: 합성 신문(1934.8.1~12.22)"]
        lines.reserveCapacity(paragraphPairs * 2 + 4)
        let sentence = "그들에게서 들으면 이러하였다. 마을 앞 넓은 들판에는 차가운 가을 바람이 불고 사람들은 긴 황톳길을 걸어갔다."
        for index in 0..<paragraphPairs {
            lines.append("제\(index + 1)문단 \(sentence)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func testCursorMoveAndLineEditsDoNotTriggerFullSerialCacheRebuildInLongNovel() {
        let novel = makeSyntheticNovel(paragraphPairs: 3_300)
        XCTAssertGreaterThan(novel.utf16.count, 230_000)

        let view = makeEditor()
        view.load(markdown: novel)
        _ = view.serialize()
        let initialRebuilds = view.serialCacheRebuildCount

        // Move caret across distant paragraphs and type in each paragraph.
        for marker in ["제100문단", "제1500문단", "제3000문단", "제500문단"] {
            let range = (view.string as NSString).range(of: marker)
            XCTAssertNotEqual(range.location, NSNotFound)
            view.setSelectedRange(NSRange(location: range.upperBound, length: 0))
            view.insertText(" 추가", replacementRange: view.selectedRange())
            _ = view.serialize()
        }

        // Split a paragraph with newline and merge it back.
        let splitTarget = (view.string as NSString).range(of: "제2000문단")
        XCTAssertNotEqual(splitTarget.location, NSNotFound)
        view.setSelectedRange(NSRange(location: splitTarget.upperBound, length: 0))
        view.insertNewline(nil)
        _ = view.serialize()
        view.deleteBackward(nil)
        let incremental = view.serialize()

        XCTAssertEqual(
            view.serialCacheRebuildCount, initialRebuilds,
            "Moving caret to another paragraph or splitting/merging a line must not rebuild all 6,600 lines"
        )

        let fresh = makeEditor()
        fresh.load(markdown: incremental)
        XCTAssertEqual(fresh.serialize(), incremental)
    }

    func testWorkspaceWritingStatisticsMemoizesRepeatedReadsAndMatchesCounts() {
        let novel = makeSyntheticNovel(paragraphPairs: 3_300)
        let expectedLines = novel.components(separatedBy: "\n")
        let expectedCharacters = expectedLines.reduce(0) { $0 + $1.utf16.count }
        let expectedParagraphs = max(1, expectedLines.count)

        let beforeScans = WorkspaceWritingStatistics.scanCount
        var stats = WorkspaceWritingStatistics(text: novel, goal: 500)
        for _ in 0..<20 {
            stats = WorkspaceWritingStatistics(text: novel, goal: 500)
        }
        let afterScans = WorkspaceWritingStatistics.scanCount

        XCTAssertEqual(stats.characters, expectedCharacters)
        XCTAssertEqual(stats.paragraphs, expectedParagraphs)
        XCTAssertEqual(
            afterScans - beforeScans, 1,
            "Repeated reads of the same manuscript text in SwiftUI chrome must not rescan 240k characters"
        )
    }

    func testLargeNoteEditingScansOnlyHeadingsInsteadOfEveryParagraph() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction)
        defer { h.close() }
        let session = h.fixture.session
        let manuscript = try XCTUnwrap(session.selectedDocumentID)
        session.updateSelectedDocumentBody("그들에게서 들으면 합성 장편 소설의 이야기가 시작되었다.")

        let noteID = try XCTUnwrap(session.createDocument(title: "합성 장편 고증", kind: .note))
        let largeNote = makeSyntheticNovel(paragraphPairs: 3_300)
        let controller = WorkspaceEntityController(session: session, requests: h.requests)
        let scansBefore = controller.noteParagraphScanCount

        session.updateSelectedDocumentBody(largeNote)
        session.updateSelectedDocumentBody(largeNote + "\n마지막 추가 문장.")

        let scansDelta = controller.noteParagraphScanCount - scansBefore
        XCTAssertLessThan(
            scansDelta, 20,
            "Scanning a 6,600-line note for headings must jump to '#' matches instead of walking every paragraph"
        )

        session.selectDocument(manuscript)
        await h.layout()
        let editor = try await h.editor()
        controller.hover(
            editor: editor,
            key: try XCTUnwrap(session.runtimeIdentity).key,
            nativeOffset: (editor.string as NSString).range(of: "합성 장편 소설").location
        )
        XCTAssertEqual(controller.peek?.name, "합성 장편 소설")
        XCTAssertEqual(controller.peek?.reference.key.documentID, noteID)
        controller.hide()
    }

    func testSetWritingDiagnosticsReusesResolvedNativeRangesAcrossWindowUpdates() {
        let body = (0..<200).map { "문단 \($0)에서 됬다라는 표현이 나온다." }.joined(separator: "\n")
        let harness = WritingEditorHarness(body)
        defer { harness.close() }

        let ns = body as NSString
        var findings: [WritingDiagnosticsFinding] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while findings.count < 100 {
            let found = ns.range(of: "됬다", range: searchRange)
            guard found.location != NSNotFound else { break }
            findings.append(writingEditorFinding(harness, range: found))
            searchRange = NSRange(location: found.upperBound, length: ns.length - found.upperBound)
        }
        XCTAssertEqual(findings.count, 100)

        let revision = harness.editor.writingNativeRevision
        let beforeLookups = harness.editor.writingDecorationLookupCount

        // Simulate 10 incremental window publications where 10 findings are added each time.
        for step in 1...10 {
            let prefixFindings = Array(findings.prefix(step * 10))
            harness.editor.setWritingDiagnostics(prefixFindings, revision: revision)
        }

        let totalLookups = harness.editor.writingDecorationLookupCount - beforeLookups
        XCTAssertEqual(
            totalLookups, 100,
            "Incremental window publications at the same nativeRevision must resolve each finding once (100), not O(W*F) (550)"
        )
    }
}
