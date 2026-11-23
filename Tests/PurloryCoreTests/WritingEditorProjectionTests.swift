@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class WritingEditorProjectionTests: XCTestCase {
    func testUntrustedDiagnosticRangeCannotOverflowNativeLookup() {
        let harness = WritingEditorHarness("안전한 원고")
        defer { harness.close() }
        var range = WritingDiagnosticRange(location: 0, length: 1)
        range.location = Int.min // Persisted or provider coordinates may be invalid.
        XCTAssertNil(harness.editor.nativeRange(forSource: range, revision: harness.editor.writingNativeRevision))
        range.location = 0; range.length = Int.max
        XCTAssertNil(harness.editor.nativeRange(forSource: range, revision: harness.editor.writingNativeRevision))
    }

    func testBoundedStructuralLinkEditKeepsGrammarAcrossSourcePieces() throws {
        let source = "[이름](https://example.test/" + String(repeating: "a", count: 3_000) + ")"
        let harness = WritingEditorHarness(source)
        defer { harness.close() }
        let target = (harness.editor.string as NSString).range(of: "aaaa").location + 2_500
        harness.edit("(", range: NSRange(location: target, length: 0))
        harness.edit(")", range: NSRange(location: target + 2, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertNil(harness.editor.nativeRange(forSource: .init(location: target + 20, length: 1),
                                               revision: harness.editor.writingNativeRevision))
    }

    func testMixedNativeEditsKeepCapturedPatchesEqualToSavedSource() async throws {
        let harness = WritingEditorHarness("# 제목\n**같은 말** 🙂\n같은 말\n```\n코드\n```\n앞 $x$ 뒤")
        defer { harness.close() }
        var seed: UInt64 = 0x126
        func next(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(max(1, limit)))
        }
        for step in 0..<80 {
            let text = harness.editor.string
            let boundaries = text.indices.map { NSRange(text.startIndex..<$0, in: text).length } + [text.utf16.count]
            let index = next(boundaries.count), start = boundaries[index]
            if step % 4 == 0 && index + 1 < boundaries.count {
                harness.edit("", range: NSRange(location: start, length: boundaries[index + 1] - start))
            } else {
                let insertions = ["가", "🙂", "\n", " ", "끝"]
                harness.edit(insertions[next(insertions.count)], range: NSRange(location: start, length: 0))
            }
            for _ in 0..<200 {
                if harness.projectedSource == harness.body { break }
                await Task.yield()
            }
            XCTAssertTrue(harness.projectedSource == harness.body, "Exact binding/patch agreement at edit \(step)")
        }
    }

    func testDeletingAllTextThenReplacingEmptyDocumentKeepsProjectionCurrent() throws {
        let harness = WritingEditorHarness("전부 삭제")
        defer { harness.close() }
        harness.edit("", range: NSRange(location: 0, length: harness.editor.string.utf16.count))
        XCTAssertEqual(harness.projectedSource, "")
        harness.edit("다시 시작", range: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertNotNil(harness.editor.nativeRange(forSource: .init(location: 0, length: 2),
                                                 revision: harness.editor.writingNativeRevision))
    }

    func testPastedLinkSpanningDeferredPiecesNeverExposesItsDestination() async throws {
        let harness = WritingEditorHarness("앞 ")
        defer { harness.close() }
        harness.edit("[이름](https://example.test/" + String(repeating: "a", count: 9_000) + ")\n정상 문장",
                     range: NSRange(location: 2, length: 0))
        for _ in 0..<2_000 {
            if harness.projectedSource == harness.body { break }
            await Task.yield()
        }
        XCTAssertEqual(harness.projectedSource, harness.body)
        let range = (harness.body as NSString).range(of: "aaaa")
        XCTAssertNil(harness.editor.nativeRange(forSource: .init(location: range.location + 5_000, length: 1),
                                               revision: harness.editor.writingNativeRevision))
        let normal = (harness.body as NSString).range(of: "정상")
        XCTAssertNotNil(harness.editor.nativeRange(forSource: .init(normal), revision: harness.editor.writingNativeRevision))
    }

    func testBridgePairsOnlyPostBindingSnapshotAndAdoptsVerifiedProfileChanges() throws {
        let harness = WritingEditorHarness("첫 문장", useBridge: true)
        defer { harness.close() }
        harness.edit("!", range: NSRange(location: 4, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertEqual(harness.pairedIdentities.last, harness.snapshot.identity)
        XCTAssertTrue(harness.pendingPairObserved)
        harness.changeProfile()
        XCTAssertNotNil(harness.editor.nativeRange(forSource: .init(location: 0, length: 1),
                                                   revision: harness.editor.writingNativeRevision))
        harness.edit("끝", range: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        let old = try XCTUnwrap(harness.commits.first)
        let count = harness.commits.count
        harness.bridge.receive(old)
        XCTAssertEqual(harness.commits.count, count, "A delayed old native revision cannot pair with a new snapshot")
        harness.replaceOwnershipWithoutLoad()
        XCTAssertNil(harness.editor.nativeRange(forSource: .init(location: 0, length: 1),
                                                revision: harness.editor.writingNativeRevision))
        harness.edit("거부", range: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.commits.count, count)
    }

    func testNativeMapRejectsPartialComposedCharactersAndIgnoresPresentationAttributes() throws {
        let harness = WritingEditorHarness("가🙂한 끝")
        defer { harness.close() }
        let editor = harness.editor, revision = editor.writingNativeRevision
        XCTAssertNil(editor.nativeRange(forSource: .init(location: 1, length: 1), revision: revision))
        XCTAssertNil(editor.nativeRange(forSource: .init(location: 3, length: 1), revision: revision))
        XCTAssertNotNil(editor.nativeRange(forSource: .init(location: 1, length: 5), revision: revision))
        editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.red,
                                        range: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(editor.writingNativeRevision, revision)
        XCTAssertNotNil(editor.nativeRange(forSource: .init(location: 1, length: 5), revision: revision))
    }

    func testEmptyDocumentAndBlockMarkerConversionPublishExactChanges() throws {
        let harness = WritingEditorHarness("")
        defer { harness.close() }
        harness.edit("제목", range: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        harness.editor.textStorage?.addAttribute(.purloryBlock, value: "h1", range: NSRange(location: 0, length: 2))
        harness.editor.didChangeText()
        XCTAssertEqual(harness.body, "# 제목")
        XCTAssertEqual(harness.projectedSource, harness.body)
    }

    func testHugeFormattedParagraphKeepsExistingExcludedURLScope() throws {
        let url = "https://example.test/" + String(repeating: "a", count: 6_000)
        let source = "**" + String(repeating: "가", count: 150_000) + "** [이름](" + url + ") 끝"
        let harness = WritingEditorHarness(source)
        defer { harness.close() }
        harness.edit("나", range: NSRange(location: 75_000, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        let native = try XCTUnwrap(harness.editor.nativeRange(forSource: .init(location: 75_002, length: 1),
                                                              revision: harness.editor.writingNativeRevision))
        XCTAssertEqual((harness.editor.string as NSString).substring(with: native.nsRange), "나")
        let target = (harness.editor.string as NSString).range(of: "aaaa")
        harness.edit("b", range: NSRange(location: target.location + 3_000, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        let urlSource = (harness.body as NSString).range(of: "aaaa")
        XCTAssertNil(harness.editor.nativeRange(forSource: .init(location: urlSource.location + 3_000, length: 1),
                                               revision: harness.editor.writingNativeRevision))
    }

    func testLargePasteFinishesWithoutReloadAndOldDeferredWorkCannotPublish() async throws {
        let harness = WritingEditorHarness("앞\n뒤")
        defer { harness.close() }
        let editor = harness.editor, resets = editor.writingProjectionResetCount
        harness.edit(String(repeating: "새 문장\n", count: 3_000), range: NSRange(location: 2, length: 0))
        let stale = editor.writingNativeRevision
        XCTAssertNil(editor.nativeRange(forSource: .init(location: 0, length: 1), revision: stale))
        harness.edit("끝", range: NSRange(location: editor.string.utf16.count, length: 0))
        for _ in 0..<2_000 {
            if harness.projectedSource == harness.body { break }
            await Task.yield()
        }
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertEqual(editor.writingProjectionResetCount, resets)
        XCTAssertNil(editor.nativeRange(forSource: .init(location: 0, length: 1), revision: stale))
        XCTAssertNotNil(editor.nativeRange(forSource: .init(location: 0, length: 1), revision: editor.writingNativeRevision))
    }

    func testNativeRowIndexUsesBothCoordinatePrefixesAndCodeFences() throws {
        let first = NSMutableAttributedString(string: "같은 말")
        first.addAttribute(.purloryBold, value: true, range: NSRange(location: 0, length: first.length))
        let second = NSAttributedString(string: "같은 말")
        func row(_ native: NSAttributedString, newline: Bool, code: Bool = false) -> WritingSerializedRow {
            var spans: [InlineMarkdown.SerializedSpan] = []
            let text = code ? native.string : InlineMarkdown.serialize(native,
                in: NSRange(location: 0, length: native.length), capture: { spans.append($0) })
            return WritingSerializedRow(text: text, textLength: text.utf16.count,
                nativeContentLength: native.length, hasLineFeed: newline, isCode: code, eligible: !code, spans: spans)
        }
        let index = WritingNativeRowIndex()
        index.reset(rows: [row(first, newline: true), row(second, newline: false)])
        XCTAssertEqual(index.nativeRange(forSource: NSRange(location: 2, length: 4)), NSRange(location: 0, length: 4))
        XCTAssertEqual(index.nativeRange(forSource: NSRange(location: 9, length: 4)), NSRange(location: 5, length: 4))
        XCTAssertNil(index.nativeRange(forSource: NSRange(location: 0, length: 8)))
        XCTAssertEqual(index.sourceLength, 13)
        XCTAssertEqual(index.nativeLength, 9)
        let code = NSAttributedString(string: "코드"), plain = NSAttributedString(string: "말")
        index.reset(rows: [row(code, newline: true, code: true), row(plain, newline: false)])
        XCTAssertEqual(index.sourceLength, 12)
        XCTAssertEqual(index.nativeRange(forSource: NSRange(location: 11, length: 1)), NSRange(location: 3, length: 1))
        XCTAssertNil(index.nativeRange(forSource: NSRange(location: 4, length: 2)))
        XCTAssertTrue(index.replace(NSRange(location: 0, length: 3), with: [row(code, newline: true)]))
        XCTAssertEqual(index.sourceLength, 4)
        XCTAssertEqual(index.nativeRange(forSource: NSRange(location: 3, length: 1)), NSRange(location: 3, length: 1))
    }

    func testProjectionSnapshotsComposeEditsWithoutReadingUnchangedText() throws {
        let source = String(repeating: "가", count: 300_000)
        let index = WritingProjectionIndex()
        index.reset(source: source)
        let base = index.snapshot()
        for offset in [3, 4] {
            let piece = try XCTUnwrap(index.sourcePiece(containing: offset))
            let changed = (piece.block.sourceText as NSString).replacingCharacters(
                in: NSRange(location: offset - piece.range.location, length: 0), with: "나")
            XCTAssertTrue(index.apply(.init(oldSourceRange: piece.range,
                                           replacement: WritingProseProjection.blocks(source: changed))))
        }
        let patch = try XCTUnwrap(index.patch(from: base))
        XCTAssertLessThan(index.lastDiffVisits, 100)
        XCTAssertLessThanOrEqual(patch.oldSourceRange.length, 4096)
        let result = (source as NSString).replacingCharacters(in: patch.oldSourceRange.nsRange,
            with: patch.replacement.map(\.sourceText).joined())
        XCTAssertEqual(result, "가가가나나" + String(repeating: "가", count: 299_997))
        XCTAssertEqual(base.sourceLength, 300_000)
        XCTAssertNil(index.patch(from: index.snapshot()))
    }

    func testInlineSerializationCapturesNativeSpansInTheExistingPass() throws {
        let storage = NSMutableAttributedString(string: "가🙂수 코드")
        storage.addAttribute(.purloryBold, value: true, range: NSRange(location: 0, length: 3))
        storage.addAttributes([.purloryCode: true, .purloryColor: "ABCDEF"], range: NSRange(location: 5, length: 2))
        var spans: [InlineMarkdown.SerializedSpan] = []
        let source = InlineMarkdown.serialize(storage, in: NSRange(location: 0, length: storage.length), capture: { spans.append($0) })
        XCTAssertEqual(source, "**가🙂**수 <font color=\"#ABCDEF\">`코드`</font>")
        XCTAssertEqual(spans.map(\.native), [NSRange(location: 0, length: 3), NSRange(location: 3, length: 2), NSRange(location: 5, length: 2)])
        for span in spans {
            let body = try XCTUnwrap(span.body)
            XCTAssertEqual((source as NSString).substring(with: body), (storage.string as NSString).substring(with: span.native))
        }
        XCTAssertTrue(spans[0].style.bold)
        XCTAssertTrue(spans[2].style.code)
        XCTAssertEqual(spans[2].style.color, "ABCDEF")
        XCTAssertEqual(spans.last?.source.upperBound, source.utf16.count)
    }

    func testLoadAndNativeEditMapsMatchCanonicalSource() async throws {
        let source = "# 제목\n**같은 말** 🙂한\n같은 말 🙂한\n할**수** 있다.\n앞 $x$ 뒤\n![그림](asset.png)"
        let harness = WritingEditorHarness(source)
        defer { harness.close() }
        let editor = harness.editor, ns = source as NSString
        let second = ns.range(of: "같은 말", options: .backwards)
        let revision = editor.writingNativeRevision
        let native = try XCTUnwrap(editor.nativeRange(forSource: .init(second), revision: revision))
        XCTAssertEqual((editor.string as NSString).substring(with: native.nsRange), "같은 말")
        let formatted = ns.range(of: "할**수**")
        XCTAssertNil(editor.nativeRange(forSource: .init(formatted), revision: revision))
        let end = editor.string.utf16.count
        harness.edit("!", range: NSRange(location: end, length: 0))
        await Task.yield()
        editor.refreshActiveLineHighlight()
        XCTAssertGreaterThan(editor.writingNativeRevision, revision)
        XCTAssertNil(editor.nativeRange(forSource: .init(second), revision: revision))
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertEqual(harness.events.suffix(2), ["binding", "commit"])
        XCTAssertTrue(harness.commits.allSatisfy { $0.baseIdentity.key == harness.key })
    }

    func testIMEIsNeverCommittedForDiagnostics() throws {
        let harness = WritingEditorHarness("시작 ")
        defer { harness.close() }
        let editor = harness.editor
        harness.window.testUndo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText(), "Diagnostics must never unmark user composition")
        XCTAssertTrue(harness.commits.isEmpty)
        XCTAssertTrue(harness.compositions.contains { $0 != nil })
        editor.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(harness.commits.isEmpty)
        editor.unmarkText() // Explicit synthetic user commit.
        harness.window.testUndo.endUndoGrouping()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertFalse(harness.commits.isEmpty)
        XCTAssertNil(harness.compositions.last ?? nil)
        XCTAssertEqual(harness.projectedSource, harness.body)
    }

    func testHugeParagraphDeltaDoesNotReserializeForDiagnostics() throws {
        let harness = WritingEditorHarness(String(repeating: "가", count: 300_000))
        defer { harness.close() }
        let editor = harness.editor
        let resets = editor.writingProjectionResetCount
        let serializations = editor.serializationInvocationCount
        harness.edit("나", range: NSRange(location: 3, length: 0))
        XCTAssertEqual(editor.serializationInvocationCount, serializations + 1,
                       "Only the existing binding serialization may run")
        XCTAssertEqual(editor.writingProjectionResetCount, resets)
        XCTAssertLessThanOrEqual(editor.writingProjectionLastInputUTF16, 4096)
        XCTAssertEqual(harness.projectedSource, harness.body)
        let range = try XCTUnwrap(editor.nativeRange(forSource: .init(location: 3, length: 1),
                                                     revision: editor.writingNativeRevision))
        XCTAssertEqual((editor.string as NSString).substring(with: range.nsRange), "나")
        harness.edit("끝", range: NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertNotNil(editor.nativeRange(forSource: .init(location: harness.body.utf16.count - 1, length: 1),
                                          revision: editor.writingNativeRevision))
    }

    func testUndoRedoAndProgrammaticChangesEmitValidPatches() throws {
        let harness = WritingEditorHarness("첫 문장\n둘째 문장")
        defer { harness.close() }
        let editor = harness.editor
        harness.window.testUndo.beginUndoGrouping()
        harness.edit("새 ", range: NSRange(location: 0, length: 0))
        harness.window.testUndo.endUndoGrouping()
        XCTAssertEqual(harness.projectedSource, harness.body)
        harness.window.testUndo.undo()
        XCTAssertEqual(harness.projectedSource, harness.body)
        harness.window.testUndo.redo()
        XCTAssertEqual(harness.projectedSource, harness.body)
        harness.edit("\n붙인 문장", range: NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)
        let newline = (editor.string as NSString).range(of: "\n")
        harness.edit(" ", range: newline)
        XCTAssertEqual(harness.projectedSource, harness.body)
        let revision = editor.writingNativeRevision
        editor.textStorage?.addAttribute(.purloryBold, value: true, range: NSRange(location: 0, length: 1))
        editor.didChangeText()
        XCTAssertGreaterThan(editor.writingNativeRevision, revision)
        XCTAssertEqual(harness.projectedSource, harness.body)
        editor.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 1), with: "끝")
        editor.didChangeText() // Bypasses shouldChangeText, as programmatic callers do.
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertEqual(harness.body, editor.serialize())
    }

    func testKoreanIMECompositionCommitCoalescesChangesAndUsesSingleEligibleProseSegment() throws {
        let paragraph = "이것은 평범한 한글 산문 문단 하나입니다. 차분하게 다음 문장을 씁니다."
        let source = Array(repeating: paragraph, count: 40).joined(separator: "\n")
        XCTAssertGreaterThan(source.utf16.count, 1_500)
        XCTAssertLessThan(source.utf16.count, 2_048)

        let harness = WritingEditorHarness(source)
        defer { harness.close() }
        let editor = harness.editor
        let middleParagraphIndex = 20
        let caretOffset = middleParagraphIndex * (paragraph.utf16.count + 1)

        editor.setSelectedRange(NSRange(location: caretOffset, length: 0))
        XCTAssertFalse(editor.hasMarkedText())

        harness.window.testUndo.beginUndoGrouping()
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: editor.markedRange())
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("한", replacementRange: editor.markedRange())
        harness.window.testUndo.endUndoGrouping()

        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(harness.projectedSource, harness.body)

        let committedSourceRange = WritingDiagnosticRange(location: caretOffset, length: 1)
        let native = try XCTUnwrap(editor.nativeRange(forSource: committedSourceRange,
                                                      revision: editor.writingNativeRevision))
        XCTAssertEqual((editor.string as NSString).substring(with: native.nsRange), "한")

        let piece = try XCTUnwrap(editor.writingProjectionCapture.sourceProjection.sourcePiece(containing: caretOffset))
        XCTAssertEqual(piece.block.segments.count, 1)
        XCTAssertEqual(piece.block.segments.first?.eligible, true)
    }

    func testNativeRowIndexSourceIntervalsCoalescesContiguousEligibleAndBlockedRanges() throws {
        func plainRow(_ text: String, newline: Bool = true) -> WritingSerializedRow {
            let length = text.utf16.count
            let span = InlineMarkdown.SerializedSpan(
                source: NSRange(location: 0, length: length),
                body: NSRange(location: 0, length: length),
                native: NSRange(location: 0, length: length),
                style: .init()
            )
            return WritingSerializedRow(
                text: text,
                textLength: length,
                nativeContentLength: length,
                hasLineFeed: newline,
                isCode: false,
                eligible: true,
                spans: [span]
            )
        }
        func codeRow(_ text: String, newline: Bool = true) -> WritingSerializedRow {
            let length = text.utf16.count
            return WritingSerializedRow(
                text: text,
                textLength: length,
                nativeContentLength: length,
                hasLineFeed: newline,
                isCode: true,
                eligible: false,
                spans: []
            )
        }

        let leadingRows = (0..<50).map { _ in plainRow("가나다라.") } // 50 * 6 = 300 UTF-16
        let fenceBody = codeRow("let x = 1") // 9 + 1 = 10 UTF-16, flanked by 4-char ```\n fences
        let trailingRows = (0..<50).map { _ in plainRow("마바사아.") } // 50 * 6 = 300 UTF-16

        let index = WritingNativeRowIndex()
        index.reset(rows: leadingRows + [fenceBody] + trailingRows)
        XCTAssertEqual(index.sourceLength, 618)

        let full = index.sourceIntervals(in: NSRange(location: 0, length: index.sourceLength))
        XCTAssertEqual(full.eligible, [NSRange(location: 0, length: 300), NSRange(location: 318, length: 300)])
        XCTAssertEqual(full.blocked, [NSRange(location: 304, length: 10)])

        let acrossCode = index.sourceIntervals(in: NSRange(location: 296, length: 26))
        XCTAssertEqual(acrossCode.eligible, [NSRange(location: 296, length: 4), NSRange(location: 318, length: 4)])
        XCTAssertEqual(acrossCode.blocked, [NSRange(location: 304, length: 10)])

        let openingBoundary = index.sourceIntervals(in: NSRange(location: 298, length: 9))
        XCTAssertEqual(openingBoundary.eligible, [NSRange(location: 298, length: 2)])
        XCTAssertEqual(openingBoundary.blocked, [NSRange(location: 304, length: 3)])

        let closingBoundary = index.sourceIntervals(in: NSRange(location: 309, length: 12))
        XCTAssertEqual(closingBoundary.eligible, [NSRange(location: 318, length: 3)])
        XCTAssertEqual(closingBoundary.blocked, [NSRange(location: 309, length: 5)])

        let openingFenceOnly = index.sourceIntervals(in: NSRange(location: 300, length: 4))
        XCTAssertTrue(openingFenceOnly.eligible.isEmpty)
        XCTAssertTrue(openingFenceOnly.blocked.isEmpty)

        let closingFenceOnly = index.sourceIntervals(in: NSRange(location: 314, length: 4))
        XCTAssertTrue(closingFenceOnly.eligible.isEmpty)
        XCTAssertTrue(closingFenceOnly.blocked.isEmpty)
    }

    func testKoreanIMECompositionReplacingSelectionAcrossSourcePieceBoundaryPreservesProjectionAndLookup() throws {
        let harness = WritingEditorHarness(String(repeating: "가", count: 3_000))
        defer { harness.close() }
        let editor = harness.editor
        let firstPiece = try XCTUnwrap(editor.writingProjectionCapture.sourceProjection.sourcePiece(containing: 0))
        XCTAssertEqual(firstPiece.range.location, 0)
        XCTAssertEqual(firstPiece.range.length, 2_048)

        editor.setSelectedRange(NSRange(location: 2_047, length: 2))
        harness.window.testUndo.beginUndoGrouping()
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.markedRange())
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("한", replacementRange: editor.markedRange())
        harness.window.testUndo.endUndoGrouping()

        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertEqual(harness.body.utf16.count, 2_999)

        let rebuilt = WritingEditorHarness(harness.body)
        defer { rebuilt.close() }
        XCTAssertEqual(editor.writingProjectionCapture.sourceProjection.proseLength, 2_999)
        XCTAssertEqual(
            editor.writingProjectionCapture.sourceProjection.proseLength,
            rebuilt.editor.writingProjectionCapture.sourceProjection.proseLength
        )

        let native = try XCTUnwrap(editor.nativeRange(
            forSource: .init(location: 2_047, length: 1),
            revision: editor.writingNativeRevision,
            expectedQuote: "한"
        ))
        XCTAssertEqual((editor.string as NSString).substring(with: native.nsRange), "한")

        harness.window.testUndo.undo()
        XCTAssertEqual(harness.projectedSource, harness.body)
        let afterUndo = WritingEditorHarness(harness.body)
        defer { afterUndo.close() }
        XCTAssertEqual(
            editor.writingProjectionCapture.sourceProjection.proseLength,
            afterUndo.editor.writingProjectionCapture.sourceProjection.proseLength
        )

        harness.window.testUndo.redo()
        XCTAssertEqual(harness.projectedSource, harness.body)
        let afterRedo = WritingEditorHarness(harness.body)
        defer { afterRedo.close() }
        XCTAssertEqual(
            editor.writingProjectionCapture.sourceProjection.proseLength,
            afterRedo.editor.writingProjectionCapture.sourceProjection.proseLength
        )
    }

    func testSingleStepLatinGrowingReplacementAndDeletionAcrossPieceBoundaryKeepExactProjection() throws {
        let latinHarness = WritingEditorHarness(String(repeating: "가", count: 3_000))
        defer { latinHarness.close() }
        latinHarness.edit("a", range: NSRange(location: 2_047, length: 2))
        XCTAssertEqual(latinHarness.projectedSource, latinHarness.body)
        let latinRebuilt = WritingEditorHarness(latinHarness.body)
        defer { latinRebuilt.close() }
        XCTAssertEqual(latinHarness.editor.writingProjectionCapture.sourceProjection.proseLength, 2_999)
        XCTAssertEqual(
            latinHarness.editor.writingProjectionCapture.sourceProjection.proseLength,
            latinRebuilt.editor.writingProjectionCapture.sourceProjection.proseLength
        )
        let latinNative = try XCTUnwrap(latinHarness.editor.nativeRange(
            forSource: .init(location: 2_047, length: 1),
            revision: latinHarness.editor.writingNativeRevision,
            expectedQuote: "a"
        ))
        XCTAssertEqual((latinHarness.editor.string as NSString).substring(with: latinNative.nsRange), "a")

        let growingHarness = WritingEditorHarness(String(repeating: "가", count: 3_000))
        defer { growingHarness.close() }
        growingHarness.edit("가나다라", range: NSRange(location: 2_047, length: 2))
        XCTAssertEqual(growingHarness.projectedSource, growingHarness.body)
        let growingRebuilt = WritingEditorHarness(growingHarness.body)
        defer { growingRebuilt.close() }
        XCTAssertEqual(growingHarness.editor.writingProjectionCapture.sourceProjection.proseLength, 3_002)
        XCTAssertEqual(
            growingHarness.editor.writingProjectionCapture.sourceProjection.proseLength,
            growingRebuilt.editor.writingProjectionCapture.sourceProjection.proseLength
        )
        let growingNative = try XCTUnwrap(growingHarness.editor.nativeRange(
            forSource: .init(location: 2_047, length: 4),
            revision: growingHarness.editor.writingNativeRevision,
            expectedQuote: "가나다라"
        ))
        XCTAssertEqual((growingHarness.editor.string as NSString).substring(with: growingNative.nsRange), "가나다라")

        let deleteHarness = WritingEditorHarness(String(repeating: "가", count: 3_000))
        defer { deleteHarness.close() }
        deleteHarness.edit("", range: NSRange(location: 2_047, length: 2))
        XCTAssertEqual(deleteHarness.projectedSource, deleteHarness.body)
        let deleteRebuilt = WritingEditorHarness(deleteHarness.body)
        defer { deleteRebuilt.close() }
        XCTAssertEqual(deleteHarness.editor.writingProjectionCapture.sourceProjection.proseLength, 2_998)
        XCTAssertEqual(
            deleteHarness.editor.writingProjectionCapture.sourceProjection.proseLength,
            deleteRebuilt.editor.writingProjectionCapture.sourceProjection.proseLength
        )
        let deleteNative = try XCTUnwrap(deleteHarness.editor.nativeRange(
            forSource: .init(location: 2_046, length: 2),
            revision: deleteHarness.editor.writingNativeRevision
        ))
        XCTAssertEqual((deleteHarness.editor.string as NSString).substring(with: deleteNative.nsRange), "가가")
    }

    func testReplacingSelectionAcrossPieceBoundaryInsideExcludedURLKeepsURLExcluded() throws {
        let url = "https://example.test/" + String(repeating: "a", count: 6_000)
        let source = "앞 [이름](" + url + ") 끝"
        let harness = WritingEditorHarness(source)
        defer { harness.close() }
        let editor = harness.editor
        let firstPiece = try XCTUnwrap(editor.writingProjectionCapture.sourceProjection.sourcePiece(containing: 0))
        let pieceEnd = firstPiece.range.location + firstPiece.range.length
        let sourceNS = source as NSString
        let urlRange = sourceNS.range(of: url)
        XCTAssertNotEqual(urlRange.location, NSNotFound)
        let aStart = urlRange.location + "https://example.test/".utf16.count
        XCTAssertGreaterThan(pieceEnd - 1, aStart)
        XCTAssertLessThan(pieceEnd + 1, urlRange.upperBound)
        XCTAssertEqual(sourceNS.substring(with: NSRange(location: pieceEnd - 1, length: 2)), "aa")

        let nativeURL = (editor.string as NSString).range(of: "aaaa")
        XCTAssertNotEqual(nativeURL.location, NSNotFound)
        let nativeSelectionStart = nativeURL.location + (pieceEnd - 1 - aStart)
        editor.setSelectedRange(NSRange(location: nativeSelectionStart, length: 2))

        harness.window.testUndo.beginUndoGrouping()
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.markedRange())
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("한", replacementRange: editor.markedRange())
        harness.window.testUndo.endUndoGrouping()

        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertNil(editor.nativeRange(
            forSource: .init(location: pieceEnd - 1, length: 1),
            revision: editor.writingNativeRevision
        ))
        let rebuilt = WritingEditorHarness(harness.body)
        defer { rebuilt.close() }
        XCTAssertEqual(
            editor.writingProjectionCapture.sourceProjection.proseLength,
            rebuilt.editor.writingProjectionCapture.sourceProjection.proseLength
        )
        let tailSource = (harness.body as NSString).range(of: "끝", options: .backwards)
        let tailNative = try XCTUnwrap(editor.nativeRange(
            forSource: .init(tailSource),
            revision: editor.writingNativeRevision,
            expectedQuote: "끝"
        ))
        XCTAssertEqual((editor.string as NSString).substring(with: tailNative.nsRange), "끝")
    }

    func testPureInsertionAdjacentToExcludedSyntaxRemainsEligibleProse() throws {
        let mathHarness = WritingEditorHarness("앞 $x$ 뒤")
        defer { mathHarness.close() }
        let afterMathNative = (mathHarness.editor.string as NSString).range(of: " 뒤").location
        XCTAssertNotEqual(afterMathNative, NSNotFound)
        mathHarness.edit("가", range: NSRange(location: afterMathNative, length: 0))
        XCTAssertEqual(mathHarness.body, "앞 $x$가 뒤")
        XCTAssertEqual(mathHarness.projectedSource, mathHarness.body)
        let mathRebuilt = WritingEditorHarness(mathHarness.body)
        defer { mathRebuilt.close() }
        XCTAssertEqual(
            mathHarness.editor.writingProjectionCapture.sourceProjection.proseLength,
            mathRebuilt.editor.writingProjectionCapture.sourceProjection.proseLength
        )
        let insertedAfterMath = (mathHarness.body as NSString).range(of: "가")
        let afterMathLookup = try XCTUnwrap(mathHarness.editor.nativeRange(
            forSource: .init(insertedAfterMath),
            revision: mathHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))
        XCTAssertEqual((mathHarness.editor.string as NSString).substring(with: afterMathLookup.nsRange), "가")
        let mathSource = (mathHarness.body as NSString).range(of: "$x$")
        XCTAssertNil(mathHarness.editor.nativeRange(
            forSource: .init(mathSource),
            revision: mathHarness.editor.writingNativeRevision
        ))

        let prefixHarness = WritingEditorHarness("[이름](https://example.test/a)")
        defer { prefixHarness.close() }
        prefixHarness.edit("가", range: NSRange(location: 0, length: 0))
        XCTAssertEqual(prefixHarness.body, "가[이름](https://example.test/a)")
        XCTAssertEqual(prefixHarness.projectedSource, prefixHarness.body)
        let prefixRebuilt = WritingEditorHarness(prefixHarness.body)
        defer { prefixRebuilt.close() }
        XCTAssertEqual(
            prefixHarness.editor.writingProjectionCapture.sourceProjection.proseLength,
            prefixRebuilt.editor.writingProjectionCapture.sourceProjection.proseLength
        )
        let prefixLookup = try XCTUnwrap(prefixHarness.editor.nativeRange(
            forSource: .init(location: 0, length: 1),
            revision: prefixHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))
        XCTAssertEqual((prefixHarness.editor.string as NSString).substring(with: prefixLookup.nsRange), "가")
        let prefixURL = (prefixHarness.body as NSString).range(of: "https://example.test/a")
        XCTAssertNil(prefixHarness.editor.nativeRange(
            forSource: .init(prefixURL),
            revision: prefixHarness.editor.writingNativeRevision
        ))

        let suffixHarness = WritingEditorHarness("[이름](https://example.test/a)")
        defer { suffixHarness.close() }
        let eofNative = suffixHarness.editor.string.utf16.count
        suffixHarness.edit("가", range: NSRange(location: eofNative, length: 0))
        XCTAssertEqual(suffixHarness.body, "[이름](https://example.test/a)가")
        XCTAssertEqual(suffixHarness.projectedSource, suffixHarness.body)
        let suffixRebuilt = WritingEditorHarness(suffixHarness.body)
        defer { suffixRebuilt.close() }
        XCTAssertEqual(
            suffixHarness.editor.writingProjectionCapture.sourceProjection.proseLength,
            suffixRebuilt.editor.writingProjectionCapture.sourceProjection.proseLength
        )
        let insertedEOF = (suffixHarness.body as NSString).range(of: "가", options: .backwards)
        let suffixLookup = try XCTUnwrap(suffixHarness.editor.nativeRange(
            forSource: .init(insertedEOF),
            revision: suffixHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))
        XCTAssertEqual((suffixHarness.editor.string as NSString).substring(with: suffixLookup.nsRange), "가")
        let suffixURL = (suffixHarness.body as NSString).range(of: "https://example.test/a")
        XCTAssertNil(suffixHarness.editor.nativeRange(
            forSource: .init(suffixURL),
            revision: suffixHarness.editor.writingNativeRevision
        ))
    }

    private func fullProseText(of index: WritingProjectionIndex) -> String {
        var result = ""
        var cursor = 0
        while cursor < index.sourceLength, let piece = index.sourcePiece(containing: cursor) {
            result += piece.block.proseText
            cursor = piece.range.location + piece.range.length
        }
        return result
    }

    private func eligibleProseText(of index: WritingProjectionIndex) -> String {
        var result = ""
        var cursor = 0
        while cursor < index.sourceLength, let piece = index.sourcePiece(containing: cursor) {
            let proseNS = piece.block.proseText as NSString
            for segment in piece.block.segments where segment.eligible {
                result += proseNS.substring(with: segment.prose)
            }
            cursor = piece.range.location + piece.range.length
        }
        return result
    }

    private func waitForDeferredProjection(_ harness: WritingEditorHarness, maxYields: Int = 2_000) async {
        for _ in 0..<maxYields {
            if harness.projectedSource == harness.body,
               harness.editor.writingProjectionCapture.mappedRevision == harness.editor.writingNativeRevision {
                break
            }
            await Task.yield()
        }
    }

    func testPureInsertionAtBlockAndFormattingLinkBoundariesRemainsEligibleProse() throws {
        // Heading prefix + link: insert at native 0.
        let headingHarness = WritingEditorHarness("# [이름](https://example.test/a)")
        defer { headingHarness.close() }
        headingHarness.edit("가", range: NSRange(location: 0, length: 0))
        XCTAssertEqual(headingHarness.body, "# 가[이름](https://example.test/a)")
        XCTAssertEqual(headingHarness.projectedSource, headingHarness.body)
        let headingRebuilt = WritingEditorHarness(headingHarness.body)
        defer { headingRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: headingHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: headingRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let headingInserted = (headingHarness.body as NSString).range(of: "가")
        let headingLookup = try XCTUnwrap(headingHarness.editor.nativeRange(
            forSource: .init(headingInserted),
            revision: headingHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))
        XCTAssertEqual((headingHarness.editor.string as NSString).substring(with: headingLookup.nsRange), "가")
        let headingURL = (headingHarness.body as NSString).range(of: "https://example.test/a")
        XCTAssertNil(headingHarness.editor.nativeRange(
            forSource: .init(headingURL),
            revision: headingHarness.editor.writingNativeRevision
        ))

        // Bold formatting + link: insert at native 0 and at native end.
        let boldStartHarness = WritingEditorHarness("**[이름](https://example.test/a)**")
        defer { boldStartHarness.close() }
        boldStartHarness.edit("가", range: NSRange(location: 0, length: 0))
        XCTAssertEqual(boldStartHarness.body, "**가[이름](https://example.test/a)**")
        XCTAssertEqual(boldStartHarness.projectedSource, boldStartHarness.body)
        let boldStartRebuilt = WritingEditorHarness(boldStartHarness.body)
        defer { boldStartRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: boldStartHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: boldStartRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let boldStartInserted = (boldStartHarness.body as NSString).range(of: "가")
        XCTAssertNotNil(boldStartHarness.editor.nativeRange(
            forSource: .init(boldStartInserted),
            revision: boldStartHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))

        let boldEndHarness = WritingEditorHarness("**[이름](https://example.test/a)**")
        defer { boldEndHarness.close() }
        let boldEndOffset = boldEndHarness.editor.string.utf16.count
        boldEndHarness.edit("가", range: NSRange(location: boldEndOffset, length: 0))
        XCTAssertEqual(boldEndHarness.body, "**[이름](https://example.test/a)가**")
        XCTAssertEqual(boldEndHarness.projectedSource, boldEndHarness.body)
        let boldEndRebuilt = WritingEditorHarness(boldEndHarness.body)
        defer { boldEndRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: boldEndHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: boldEndRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let boldEndInserted = (boldEndHarness.body as NSString).range(of: "가", options: .backwards)
        XCTAssertNotNil(boldEndHarness.editor.nativeRange(
            forSource: .init(boldEndInserted),
            revision: boldEndHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))

        // Adjacent links: insert between `)` and `[`.
        let adjacentLinksHarness = WritingEditorHarness("[a](https://example.test/1)[b](https://example.test/2)")
        defer { adjacentLinksHarness.close() }
        let boundary = (adjacentLinksHarness.editor.string as NSString).range(of: ")[")
        XCTAssertNotEqual(boundary.location, NSNotFound)
        adjacentLinksHarness.edit("가", range: NSRange(location: boundary.location + 1, length: 0))
        XCTAssertEqual(adjacentLinksHarness.body, "[a](https://example.test/1)가[b](https://example.test/2)")
        XCTAssertEqual(adjacentLinksHarness.projectedSource, adjacentLinksHarness.body)
        let adjacentLinksRebuilt = WritingEditorHarness(adjacentLinksHarness.body)
        defer { adjacentLinksRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: adjacentLinksHarness.editor.writingProjectionCapture.sourceProjection),
            "a가b"
        )
        XCTAssertEqual(
            fullProseText(of: adjacentLinksHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: adjacentLinksRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let adjacentInserted = (adjacentLinksHarness.body as NSString).range(of: "가")
        XCTAssertNotNil(adjacentLinksHarness.editor.nativeRange(
            forSource: .init(adjacentInserted),
            revision: adjacentLinksHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))
    }

    func testPureInsertionAtAdjacentBarriersAndInlineImageOptionsEOFRemainsEligibleProse() throws {
        // Adjacent math + image barriers.
        let mathImageHarness = WritingEditorHarness("$x$![a](1.png)")
        defer { mathImageHarness.close() }
        let imageStart = (mathImageHarness.editor.string as NSString).range(of: "![a]").location
        XCTAssertNotEqual(imageStart, NSNotFound)
        mathImageHarness.edit("가", range: NSRange(location: imageStart, length: 0))
        XCTAssertEqual(mathImageHarness.body, "$x$가![a](1.png)")
        XCTAssertEqual(mathImageHarness.projectedSource, mathImageHarness.body)
        let mathImageRebuilt = WritingEditorHarness(mathImageHarness.body)
        defer { mathImageRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: mathImageHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: mathImageRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let mathImageInserted = (mathImageHarness.body as NSString).range(of: "가")
        XCTAssertNotNil(mathImageHarness.editor.nativeRange(
            forSource: .init(mathImageInserted),
            revision: mathImageHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))

        // Adjacent image + image barriers.
        let imagePairHarness = WritingEditorHarness("![a](1.png)![b](2.png)")
        defer { imagePairHarness.close() }
        let secondImageStart = (imagePairHarness.editor.string as NSString).range(of: "![b]").location
        XCTAssertNotEqual(secondImageStart, NSNotFound)
        imagePairHarness.edit("가", range: NSRange(location: secondImageStart, length: 0))
        XCTAssertEqual(imagePairHarness.body, "![a](1.png)가![b](2.png)")
        XCTAssertEqual(imagePairHarness.projectedSource, imagePairHarness.body)
        let imagePairRebuilt = WritingEditorHarness(imagePairHarness.body)
        defer { imagePairRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: imagePairHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: imagePairRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let imagePairInserted = (imagePairHarness.body as NSString).range(of: "가")
        XCTAssertNotNil(imagePairHarness.editor.nativeRange(
            forSource: .init(imagePairInserted),
            revision: imagePairHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))

        // Prefix/formatting + math barrier at native 0.
        for source in ["# $x$", "**$x$**"] {
            let harness = WritingEditorHarness(source)
            defer { harness.close() }
            harness.edit("가", range: NSRange(location: 0, length: 0))
            XCTAssertEqual(harness.projectedSource, harness.body)
            let rebuilt = WritingEditorHarness(harness.body)
            defer { rebuilt.close() }
            XCTAssertEqual(
                fullProseText(of: harness.editor.writingProjectionCapture.sourceProjection),
                fullProseText(of: rebuilt.editor.writingProjectionCapture.sourceProjection),
                "Expected live projection to match fresh rebuild for \(source)"
            )
            let inserted = (harness.body as NSString).range(of: "가")
            XCTAssertNotNil(harness.editor.nativeRange(
                forSource: .init(inserted),
                revision: harness.editor.writingNativeRevision,
                expectedQuote: "가"
            ))
        }

        // Inline image with `{options}` at EOF.
        let imageOptionsHarness = WritingEditorHarness("앞 ![alt](a.png){w=50%}")
        defer { imageOptionsHarness.close() }
        let eofNative = imageOptionsHarness.editor.string.utf16.count
        imageOptionsHarness.edit("가", range: NSRange(location: eofNative, length: 0))
        XCTAssertEqual(imageOptionsHarness.body, "앞 ![alt](a.png){w=50%}가")
        XCTAssertEqual(imageOptionsHarness.projectedSource, imageOptionsHarness.body)
        let imageOptionsRebuilt = WritingEditorHarness(imageOptionsHarness.body)
        defer { imageOptionsRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: imageOptionsHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: imageOptionsRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let eofInserted = (imageOptionsHarness.body as NSString).range(of: "가", options: .backwards)
        let eofLookup = try XCTUnwrap(imageOptionsHarness.editor.nativeRange(
            forSource: .init(eofInserted),
            revision: imageOptionsHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))
        XCTAssertEqual((imageOptionsHarness.editor.string as NSString).substring(with: eofLookup.nsRange), "가")
    }

    func testPureInsertionAtEOFOfUnresolvedDeferredReferenceDoesNotExposeTail() async throws {
        let harness = WritingEditorHarness("앞 ")
        defer { harness.close() }
        let unclosed = "[name](https://example.test/" + String(repeating: "a", count: 5_000) + "(b)"
        harness.edit(unclosed, range: NSRange(location: 2, length: 0))
        await waitForDeferredProjection(harness)
        XCTAssertEqual(harness.projectedSource, harness.body)

        harness.edit("가", range: NSRange(location: harness.editor.string.utf16.count, length: 0))
        await waitForDeferredProjection(harness)
        XCTAssertEqual(harness.projectedSource, harness.body)

        let bodyNS = harness.body as NSString
        let insertedTail = bodyNS.range(of: "가", options: .backwards)
        XCTAssertNil(harness.editor.nativeRange(
            forSource: .init(insertedTail),
            revision: harness.editor.writingNativeRevision
        ))
        let urlTail = bodyNS.range(of: "aaaa")
        XCTAssertNil(harness.editor.nativeRange(
            forSource: .init(location: urlTail.location + 4_500, length: 1),
            revision: harness.editor.writingNativeRevision
        ))
        let parenTail = bodyNS.range(of: "(b)")
        XCTAssertNil(harness.editor.nativeRange(
            forSource: .init(parenTail),
            revision: harness.editor.writingNativeRevision
        ))

        let deferredRebuilt = WritingEditorHarness("앞 ")
        defer { deferredRebuilt.close() }
        deferredRebuilt.edit(unclosed + "가", range: NSRange(location: 2, length: 0))
        await waitForDeferredProjection(deferredRebuilt)
        XCTAssertEqual(
            fullProseText(of: harness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: deferredRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
    }

    func testMultiPieceFallbackOnInheritedNilKeepsExcludedImageURLOutOfProse() async throws {
        // Large (>4096) inline image replacing `"} "` across barrier and prose falls back to full-row deferred path.
        let largeSource = "앞 ![alt](https://example.test/" + String(repeating: "a", count: 6_000) + "){w=50%} 끝"
        let largeHarness = WritingEditorHarness(largeSource)
        defer { largeHarness.close() }
        let closingBraceAndSpace = (largeHarness.editor.string as NSString).range(of: "} ")
        XCTAssertNotEqual(closingBraceAndSpace.location, NSNotFound)
        largeHarness.edit("x", range: closingBraceAndSpace)
        await waitForDeferredProjection(largeHarness)
        XCTAssertEqual(largeHarness.projectedSource, largeHarness.body)
        let largeURL = (largeHarness.body as NSString).range(of: "aaaa")
        XCTAssertNil(largeHarness.editor.nativeRange(
            forSource: .init(location: largeURL.location + 5_000, length: 1),
            revision: largeHarness.editor.writingNativeRevision
        ))
        let deferredRebuilt = WritingEditorHarness("")
        defer { deferredRebuilt.close() }
        deferredRebuilt.edit(largeHarness.body, range: NSRange(location: 0, length: 0))
        await waitForDeferredProjection(deferredRebuilt)
        XCTAssertEqual(
            fullProseText(of: largeHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: deferredRebuilt.editor.writingProjectionCapture.sourceProjection)
        )

        // Multi-piece (<=4096) inline image with non-punctuation EOF insertion falls back synchronously to full-row coverage.
        let boundedSource = "앞 ![alt](https://example.test/" + String(repeating: "a", count: 3_000) + "){w=50%}"
        let boundedHarness = WritingEditorHarness(boundedSource)
        defer { boundedHarness.close() }
        boundedHarness.edit("가", range: NSRange(location: boundedHarness.editor.string.utf16.count, length: 0))
        XCTAssertEqual(boundedHarness.projectedSource, boundedHarness.body)
        let boundedRebuilt = WritingEditorHarness(boundedHarness.body)
        defer { boundedRebuilt.close() }
        XCTAssertEqual(
            eligibleProseText(of: boundedHarness.editor.writingProjectionCapture.sourceProjection),
            "앞 가"
        )
        XCTAssertEqual(
            eligibleProseText(of: boundedHarness.editor.writingProjectionCapture.sourceProjection),
            eligibleProseText(of: boundedRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let boundedPrefix = (boundedHarness.body as NSString).range(of: "앞 ")
        XCTAssertNotNil(boundedHarness.editor.nativeRange(
            forSource: .init(boundedPrefix),
            revision: boundedHarness.editor.writingNativeRevision,
            expectedQuote: "앞 "
        ))
        let boundedURL = (boundedHarness.body as NSString).range(of: "aaaa")
        XCTAssertNil(boundedHarness.editor.nativeRange(
            forSource: .init(location: boundedURL.location + 2_500, length: 1),
            revision: boundedHarness.editor.writingNativeRevision
        ))
        let boundedInserted = (boundedHarness.body as NSString).range(of: "가", options: .backwards)
        XCTAssertNotNil(boundedHarness.editor.nativeRange(
            forSource: .init(boundedInserted),
            revision: boundedHarness.editor.writingNativeRevision,
            expectedQuote: "가"
        ))
    }

    func testInlineImageOptionBracesTriggerReparse() throws {
        // Deleting closing brace turns `{w=50% 뒤` into eligible prose.
        let deleteBraceHarness = WritingEditorHarness("앞 ![alt](a.png){w=50%} 뒤")
        defer { deleteBraceHarness.close() }
        let closingBrace = (deleteBraceHarness.editor.string as NSString).range(of: "}")
        XCTAssertNotEqual(closingBrace.location, NSNotFound)
        deleteBraceHarness.edit("", range: closingBrace)
        XCTAssertEqual(deleteBraceHarness.body, "앞 ![alt](a.png){w=50% 뒤")
        XCTAssertEqual(deleteBraceHarness.projectedSource, deleteBraceHarness.body)
        let deleteBraceRebuilt = WritingEditorHarness(deleteBraceHarness.body)
        defer { deleteBraceRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: deleteBraceHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: deleteBraceRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let exposedOption = (deleteBraceHarness.body as NSString).range(of: "w=50%")
        XCTAssertNotNil(deleteBraceHarness.editor.nativeRange(
            forSource: .init(exposedOption),
            revision: deleteBraceHarness.editor.writingNativeRevision,
            expectedQuote: "w=50%"
        ))

        // Inserting `{` and `}` joins `{w=50%}` to the image barrier.
        let insertBracesHarness = WritingEditorHarness("앞 ![alt](a.png)w=50% 뒤")
        defer { insertBracesHarness.close() }
        let afterParen = (insertBracesHarness.editor.string as NSString).range(of: ")w").location + 1
        insertBracesHarness.edit("{", range: NSRange(location: afterParen, length: 0))
        let afterPercent = (insertBracesHarness.editor.string as NSString).range(of: "% ").location + 1
        insertBracesHarness.edit("}", range: NSRange(location: afterPercent, length: 0))
        XCTAssertEqual(insertBracesHarness.body, "앞 ![alt](a.png){w=50%} 뒤")
        XCTAssertEqual(insertBracesHarness.projectedSource, insertBracesHarness.body)
        let insertBracesRebuilt = WritingEditorHarness(insertBracesHarness.body)
        defer { insertBracesRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: insertBracesHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: insertBracesRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let hiddenOption = (insertBracesHarness.body as NSString).range(of: "w=50%")
        XCTAssertNil(insertBracesHarness.editor.nativeRange(
            forSource: .init(hiddenOption),
            revision: insertBracesHarness.editor.writingNativeRevision
        ))
    }

    func testWhitespaceInsideLinkDestinationTriggersReparse() throws {
        // Inserting whitespace breaks link destination grammar -> entire text becomes eligible prose.
        let breakLinkHarness = WritingEditorHarness("[이름](https://example.test/abc)")
        defer { breakLinkHarness.close() }
        let beforeAbc = (breakLinkHarness.editor.string as NSString).range(of: "abc").location
        XCTAssertNotEqual(beforeAbc, NSNotFound)
        breakLinkHarness.edit(" ", range: NSRange(location: beforeAbc, length: 0))
        XCTAssertEqual(breakLinkHarness.body, "[이름](https://example.test/ abc)")
        XCTAssertEqual(breakLinkHarness.projectedSource, breakLinkHarness.body)
        let breakLinkRebuilt = WritingEditorHarness(breakLinkHarness.body)
        defer { breakLinkRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: breakLinkHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: breakLinkRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let abcRange = (breakLinkHarness.body as NSString).range(of: "abc")
        XCTAssertNotNil(breakLinkHarness.editor.nativeRange(
            forSource: .init(abcRange),
            revision: breakLinkHarness.editor.writingNativeRevision,
            expectedQuote: "abc"
        ))

        // Deleting whitespace restores valid link destination -> URL becomes excluded again.
        let restoreLinkHarness = WritingEditorHarness("[이름](https://example.test/ abc)")
        defer { restoreLinkHarness.close() }
        let spaceRange = (restoreLinkHarness.editor.string as NSString).range(of: " ")
        XCTAssertNotEqual(spaceRange.location, NSNotFound)
        restoreLinkHarness.edit("", range: spaceRange)
        XCTAssertEqual(restoreLinkHarness.body, "[이름](https://example.test/abc)")
        XCTAssertEqual(restoreLinkHarness.projectedSource, restoreLinkHarness.body)
        let restoreLinkRebuilt = WritingEditorHarness(restoreLinkHarness.body)
        defer { restoreLinkRebuilt.close() }
        XCTAssertEqual(
            fullProseText(of: restoreLinkHarness.editor.writingProjectionCapture.sourceProjection),
            fullProseText(of: restoreLinkRebuilt.editor.writingProjectionCapture.sourceProjection)
        )
        let excludedURLRange = (restoreLinkHarness.body as NSString).range(of: "abc")
        XCTAssertNil(restoreLinkHarness.editor.nativeRange(
            forSource: .init(excludedURLRange),
            revision: restoreLinkHarness.editor.writingNativeRevision
        ))
    }

    func testNativeRowIndexSourceIntervalsClampsOverflowAndHandlesLanguageAndTrailingCodeBlock() throws {
        func plainRow(_ text: String, newline: Bool = true) -> WritingSerializedRow {
            let length = text.utf16.count
            let span = InlineMarkdown.SerializedSpan(
                source: NSRange(location: 0, length: length),
                body: NSRange(location: 0, length: length),
                native: NSRange(location: 0, length: length),
                style: .init()
            )
            return WritingSerializedRow(
                text: text,
                textLength: length,
                nativeContentLength: length,
                hasLineFeed: newline,
                isCode: false,
                eligible: true,
                spans: [span]
            )
        }
        func codeRow(_ text: String, lang: String?, newline: Bool = true) -> WritingSerializedRow {
            let length = text.utf16.count
            let attributes: [NSAttributedString.Key: Any] = lang.map { [.purloryCodeLang: $0] } ?? [:]
            return WritingSerializedRow(
                text: text,
                textLength: length,
                nativeContentLength: length,
                hasLineFeed: newline,
                isCode: true,
                eligible: false,
                blockStyle: WritingSerializedBlockStyle(attributes),
                spans: []
            )
        }

        // Layout:
        // [0..<6):   "가나다라.\n" (eligible, 6)
        // [6..<15):  "```swift\n" (open fence, 9)
        // [15..<25): "let x = 1\n" (blocked, 10)
        // [25..<29): "```\n" (close fence, 4)
        // [29..<35): "마바사아.\n" (eligible, 6)
        // [35..<44): "```swift\n" (open fence, 9)
        // [44..<50): "end()\n" (blocked, 6)
        // [50..<54): "```\n" (trailing close fence, 4)
        let index = WritingNativeRowIndex()
        index.reset(rows: [
            plainRow("가나다라."),
            codeRow("let x = 1", lang: "swift"),
            plainRow("마바사아."),
            codeRow("end()", lang: "swift")
        ])
        XCTAssertEqual(index.sourceLength, 54)

        let full = index.sourceIntervals(in: NSRange(location: 0, length: index.sourceLength))
        XCTAssertEqual(full.eligible, [NSRange(location: 0, length: 6), NSRange(location: 29, length: 6)])
        XCTAssertEqual(full.blocked, [NSRange(location: 15, length: 10), NSRange(location: 44, length: 6)])

        // Overflowing NSRange clamps safely without trapping.
        let clamped = index.sourceIntervals(in: NSRange(location: 10, length: Int.max))
        XCTAssertEqual(clamped.eligible, [NSRange(location: 29, length: 6)])
        XCTAssertEqual(clamped.blocked, [NSRange(location: 15, length: 10), NSRange(location: 44, length: 6)])

        let outOfBounds = index.sourceIntervals(in: NSRange(location: Int.max, length: 1))
        XCTAssertTrue(outOfBounds.eligible.isEmpty)
        XCTAssertTrue(outOfBounds.blocked.isEmpty)
    }

    func testPrecedingParagraphSplitURLStaysExcludedOnNextParagraphSpaceAndFallbackEdit() throws {
        // Test both long and short URLs straddling a 2048-UTF-16 piece boundary.
        let cases: [(name: String, url: String, leadCount: Int)] = [
            ("preceding-short-url", "https://ex.co/tail", 2_030),
            ("preceding-long-url", "https://example.test/" + String(repeating: "a", count: 800) + "/tail", 1_700),
        ]
        for testCase in cases {
            let lead = String(repeating: "가", count: testCase.leadCount)
            let source = lead + "[참고](" + testCase.url + ")\n다음 문단의 일반단어입니다."
            let harness = WritingEditorHarness(source)
            defer { harness.close() }

            let initialBodyNS = harness.body as NSString
            let initialTail = initialBodyNS.range(of: "tail")
            XCTAssertNotEqual(initialTail.location, NSNotFound)
            XCTAssertNil(
                harness.editor.nativeRange(
                    forSource: .init(initialTail),
                    revision: harness.editor.writingNativeRevision
                ),
                "\(testCase.name): URL tail must start excluded"
            )

            // 1. Insert a space inside a plain word in the next paragraph.
            let wordRange = (harness.editor.string as NSString).range(of: "일반단어")
            XCTAssertNotEqual(wordRange.location, NSNotFound)
            harness.edit(" ", range: NSRange(location: wordRange.location + 2, length: 0))
            XCTAssertEqual(harness.projectedSource, harness.body)

            let afterSpaceNS = harness.body as NSString
            let afterSpaceTail = afterSpaceNS.range(of: "tail")
            XCTAssertNil(
                harness.editor.nativeRange(
                    forSource: .init(afterSpaceTail),
                    revision: harness.editor.writingNativeRevision
                ),
                "\(testCase.name): URL tail must stay excluded after inserting space in next paragraph"
            )

            // 2. Also exercise an explicit syntax fallback edit (`*`) in the next paragraph.
            let endOffset = harness.editor.string.utf16.count
            harness.edit("*", range: NSRange(location: endOffset, length: 0))
            XCTAssertEqual(harness.projectedSource, harness.body)

            let afterFallbackNS = harness.body as NSString
            let afterFallbackTail = afterFallbackNS.range(of: "tail")
            XCTAssertNil(
                harness.editor.nativeRange(
                    forSource: .init(afterFallbackTail),
                    revision: harness.editor.writingNativeRevision
                ),
                "\(testCase.name): URL tail must stay excluded after full-row fallback edit in next paragraph"
            )

            let rebuilt = WritingEditorHarness(harness.body)
            defer { rebuilt.close() }
            XCTAssertEqual(
                eligibleProseText(of: harness.editor.writingProjectionCapture.sourceProjection),
                eligibleProseText(of: rebuilt.editor.writingProjectionCapture.sourceProjection),
                "\(testCase.name): live eligible prose must match fresh reload"
            )
        }
    }

    func testFollowingParagraphSplitURLStaysExcludedOnPreviousParagraphFallbackEdit() throws {
        // Place the start of a link right before the 2048-UTF-16 piece boundary in the second paragraph.
        let firstParagraph = "앞 문단의 평문입니다."
        let secondLead = String(repeating: "나", count: 2_048 - firstParagraph.utf16.count - 1 - 16)
        let source = firstParagraph + "\n" + secondLead + "[참고](https://example.test/tail) 끝"
        let harness = WritingEditorHarness(source)
        defer { harness.close() }

        // Trigger a fallback edit (`*`) in the first paragraph, whose piece suffix ends mid-link.
        harness.edit("*", range: NSRange(location: 2, length: 0))
        XCTAssertEqual(harness.projectedSource, harness.body)

        let bodyNS = harness.body as NSString
        let urlPart = bodyNS.range(of: "example")
        XCTAssertNotEqual(urlPart.location, NSNotFound)
        XCTAssertNil(
            harness.editor.nativeRange(
                forSource: .init(urlPart),
                revision: harness.editor.writingNativeRevision
            ),
            "Split URL head in untouched suffix paragraph must remain excluded"
        )

        let rebuilt = WritingEditorHarness(harness.body)
        defer { rebuilt.close() }
        XCTAssertEqual(
            eligibleProseText(of: harness.editor.writingProjectionCapture.sourceProjection),
            eligibleProseText(of: rebuilt.editor.writingProjectionCapture.sourceProjection)
        )
    }

    func testLongParagraphLinksPreserveFollowingProseAfterSpaceBeforeLink() async throws {
        let cases: [(name: String, prefix: String, leadCount: Int, url: String, tailCount: Int)] = [
            // >4096-char paragraph with short URL straddling a 2048-char chunk boundary.
            ("short-url-following-prose", "", 2_032, "https://ex.co/a", 2_500),
            // >4096-char paragraph with longer URL straddling a 2048-char chunk boundary.
            ("following-prose", "앞 문단.\n", 1_900, "https://example.test/" + String(repeating: "u", count: 600), 2_600),
            // >4096-char paragraph containing a plain `[주석]` bracket before a link.
            ("plain-bracket-before-link", "", 500, "https://ex.co/b", 3_800),
        ]

        for testCase in cases {
            let lead = testCase.name == "plain-bracket-before-link"
                ? "[주석] " + String(repeating: "가", count: testCase.leadCount)
                : String(repeating: "가", count: testCase.leadCount)
            let tail = " 정상단어 " + String(repeating: "다", count: testCase.tailCount)
            let source = testCase.prefix + lead + "[참고](" + testCase.url + ")" + tail
            let harness = WritingEditorHarness(source)
            defer { harness.close() }

            let initialBodyNS = harness.body as NSString
            let initialFollowing = initialBodyNS.range(of: "정상단어")
            XCTAssertNotEqual(initialFollowing.location, NSNotFound)
            XCTAssertNotNil(
                harness.editor.nativeRange(
                    forSource: .init(initialFollowing),
                    revision: harness.editor.writingNativeRevision,
                    expectedQuote: "정상단어"
                ),
                "\(testCase.name): following prose must start eligible"
            )

            // Insert a space before the link in the same piece as the link (triggering fallback -> deferred).
            let linkStart = (harness.editor.string as NSString).range(of: "[참고](").location
            XCTAssertNotEqual(linkStart, NSNotFound)
            let insertAt = max(testCase.prefix.utf16.count + 1, linkStart - 10)
            harness.edit(" ", range: NSRange(location: insertAt, length: 0))
            await waitForDeferredProjection(harness)
            XCTAssertEqual(harness.projectedSource, harness.body)

            let bodyNS = harness.body as NSString
            let following = bodyNS.range(of: "정상단어")
            XCTAssertNotNil(
                harness.editor.nativeRange(
                    forSource: .init(following),
                    revision: harness.editor.writingNativeRevision,
                    expectedQuote: "정상단어"
                ),
                "\(testCase.name): prose after link must remain eligible after deferred projection"
            )
            let urlHost = bodyNS.range(of: "https://")
            XCTAssertNil(
                harness.editor.nativeRange(
                    forSource: .init(urlHost),
                    revision: harness.editor.writingNativeRevision
                ),
                "\(testCase.name): link URL must remain excluded"
            )

            let rebuilt = WritingEditorHarness(harness.body)
            defer { rebuilt.close() }
            XCTAssertEqual(
                eligibleProseText(of: harness.editor.writingProjectionCapture.sourceProjection),
                eligibleProseText(of: rebuilt.editor.writingProjectionCapture.sourceProjection),
                "\(testCase.name): live eligible prose must match fresh reload"
            )
        }
    }

    func testLongParagraphSplitImageBangAtChunkBoundaryMatchesFreshRebuild() async throws {
        // After inserting `*` at offset 10, `!` sits at UTF-16 offset 2047 and `[` sits at 2048.
        let source = String(repeating: "가", count: 2_046) + "![그림](https://ex.co/img.png) 정상단어 " + String(repeating: "다", count: 2_200)
        let harness = WritingEditorHarness(source)
        defer { harness.close() }

        harness.edit("*", range: NSRange(location: 10, length: 0))
        await waitForDeferredProjection(harness)
        XCTAssertEqual(harness.projectedSource, harness.body)

        let bodyNS = harness.body as NSString
        let imageAlt = bodyNS.range(of: "그림")
        XCTAssertNil(
            harness.editor.nativeRange(
                forSource: .init(imageAlt),
                revision: harness.editor.writingNativeRevision
            ),
            "Image alt must stay excluded even when `!` and `[` straddle a 2048 boundary"
        )
        let following = bodyNS.range(of: "정상단어")
        XCTAssertNotNil(
            harness.editor.nativeRange(
                forSource: .init(following),
                revision: harness.editor.writingNativeRevision,
                expectedQuote: "정상단어"
            ),
            "Prose after image must remain eligible"
        )

        let rebuilt = WritingEditorHarness(harness.body)
        defer { rebuilt.close() }
        XCTAssertEqual(
            eligibleProseText(of: harness.editor.writingProjectionCapture.sourceProjection),
            eligibleProseText(of: rebuilt.editor.writingProjectionCapture.sourceProjection)
        )
    }
}

@MainActor
final class WritingEditorHarness {
    let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
    let window = LegacyUndoWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
    let editor: BlockTextView
    private var coordinator: PurloryBlockEditor.Coordinator!
    private var generation: UInt64 = 1
    var body: String
    var projectedSource: String
    var commits: [WritingEditorCommit] = []
    var compositions: [WritingDiagnosticRange?] = []
    var events: [String] = []
    let bridge = ProjectEditorBridge()
    var pairedIdentities: [ProjectRuntimeIdentity] = []
    var pendingPairObserved = false
    private var usesBridge = false
    private var alternateKey: ProjectDocumentKey?
    var snapshot: ProjectDocumentSnapshot {
        .init(identity: .init(key: alternateKey ?? key, generation: generation), title: "Synthetic",
              body: body, kind: .manuscript, mode: .general)
    }
    func changeProfile() { generation &+= 1; bridge.noteSnapshot(snapshot) }
    func replaceOwnershipWithoutLoad() {
        alternateKey = .init(projectID: WritingProjectID(), documentID: WritingDocumentID())
        generation &+= 1; bridge.noteSnapshot(snapshot)
        alternateKey = nil; generation &+= 1; bridge.noteSnapshot(snapshot)
    }

    init(_ source: String, useBridge: Bool = false) {
        body = source; projectedSource = source
        let storage = NSTextStorage(), layout = PurloryLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 650, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 450), textContainer: container)
        storage.delegate = editor
        editor.allowsUndo = true
        window.isReleasedWhenClosed = false
        window.testUndo.groupsByEvent = false
        window.contentView = editor
        let binding = Binding<String>(get: { [unowned self] in body }, set: { [unowned self] value in
            body = value; generation &+= 1; events.append("binding")
            if usesBridge {
                let count = commits.count
                bridge.noteSnapshot(snapshot)
                pendingPairObserved = commits.count == count
            }
        })
        let representable = PurloryBlockEditor(text: binding, documentIdentity: .project(key))
        coordinator = representable.makeCoordinator()
        editor.delegate = coordinator
        editor.writingRuntimeIdentityProvider = { [unowned self] in
            ProjectRuntimeIdentity(key: key, generation: generation)
        }
        func accept(_ commit: WritingEditorCommit) {
            self.commits.append(commit); self.events.append("commit")
            let replacement = commit.patch.replacement.map(\.sourceText).joined()
            let old = commit.patch.oldSourceRange.nsRange
            guard old.location <= self.projectedSource.utf16.count,
                  old.length <= self.projectedSource.utf16.count - old.location else { XCTFail("Invalid source patch"); return }
            self.projectedSource = (self.projectedSource as NSString).replacingCharacters(in: old, with: replacement)
        }
        editor.writingCommitDidChange = { commit in accept(commit) }
        usesBridge = useBridge
        if useBridge {
            bridge.connect(editor, currentSnapshot: { [unowned self] in snapshot })
            bridge.commitDidChange = { [unowned self] commit, snapshot in
                pairedIdentities.append(snapshot.identity); accept(commit)
            }
        }
        editor.writingCompositionDidChange = { [unowned self] range in compositions.append(range) }
        window.testUndo.beginUndoGrouping()
        editor.load(markdown: source)
        coordinator.lastSyncedText = source
        coordinator.loadedDocumentIdentity = .project(key)
        coordinator.attach(to: editor)
        window.makeFirstResponder(editor)
        window.testUndo.endUndoGrouping()
        window.testUndo.removeAllActions()
        commits.removeAll(); compositions.removeAll(); events.removeAll()
    }
    func edit(_ text: String, range: NSRange) {
        let group = window.testUndo.groupingLevel == 0
        if group { window.testUndo.beginUndoGrouping() }
        editor.insertText(text, replacementRange: range)
        if group { window.testUndo.endUndoGrouping() }
    }
    func close() {
        bridge.disconnect(editor)
        bridge.commitDidChange = nil
        editor.writingRuntimeIdentityProvider = nil
        editor.writingCommitDidChange = nil
        editor.writingCompositionDidChange = nil
        while window.testUndo.groupingLevel > 0 { window.testUndo.endUndoGrouping() }
        window.testUndo.removeAllActions()
        window.testUndo.disableUndoRegistration()
        window.contentView = nil; window.close()
    }
}
