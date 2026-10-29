@testable import PurloryDocumentEngine
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore

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
