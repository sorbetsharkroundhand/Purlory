import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI
@testable import PurloryStorage
@testable import PurloryDocumentEngine

/// Synthetic native input comparison, not a claim about hardware IME event latency.
@MainActor
final class LongDocumentInputLatencyTests: XCTestCase {
    func testCaretGeometryDoesNotGenerateTheOffscreenDocument() throws {
        let storage = NSTextStorage(), manager = NSLayoutManager()
        let counter = GlyphGenerationCounter()
        manager.delegate = counter
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 650, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        let editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 500), textContainer: container)
        editor.load(markdown: String(repeating: "한글 문단입니다.\n", count: 30_000))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        manager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length),
                                 changeInLength: 0, actualCharacterRange: nil)
        counter.generated = 0
        manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: 10))
        _ = manager.glyphIndexForCharacter(at: 3)
        let nativeWork = counter.generated
        manager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length),
                                 changeInLength: 0, actualCharacterRange: nil)
        counter.generated = 0
        let geometry = try XCTUnwrap(editor.caretLineGeometry())
        XCTAssertGreaterThan(geometry.fragment.height, 0)
        XCTAssertLessThanOrEqual(counter.generated, nativeWork,
                          "A caret needs its local line, not glyph generation for the entire manuscript")
    }

    func testEditingLargeNoteDoesNotMaterializeTheDocumentForEntityCards() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction)
        defer { h.close() }
        _ = try XCTUnwrap(h.fixture.session.createDocument(title: "Synthetic note", kind: .note))
        let body = "# 합성 자료\n" + String(repeating: "사람들이 마을의 긴 길을 걸으며 이야기를 나누었다.\n\n", count: 3300)
        h.fixture.session.updateSelectedDocumentBody(body)
        let editor = try await h.editor()
        h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 500, length: 0))
        h.window.testUndo.beginUndoGrouping()
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("한", replacementRange: editor.markedRange())
        h.window.testUndo.endUndoGrouping()
        let source = try XCTUnwrap(h.fixture.session.selectedDocument?.source)
        XCTAssertEqual(source.materializationCount, 0,
                       "Entity cards must not join and hash the whole note on each Hangul commit")
        XCTAssertFalse(editor.hasMarkedText())
        h.window.testUndo.beginUndoGrouping()
        editor.insertText("글", replacementRange: NSRange(location: 500, length: 1))
        h.window.testUndo.endUndoGrouping()
        XCTAssertEqual(h.fixture.session.selectedDocument?.source.materializationCount, 0,
                       "An equal-length replacement must compare source versions, not full note strings")
    }

    func testResumeBriefDoesNotMaterializeEqualLengthEditedManuscriptOrLargeNotes() throws {
        let manuscriptBody = "# 1장\n\n" + String(repeating: "여름밤 내내 이웃집에서 음악이 흘러나왔다.\n\n", count: 6_000)
        let noteBody = "[본편] 첫 번째 메모\n" + String(repeating: "참고 설정 문단입니다.\n", count: 6_000) + "- [본편] 마지막 메모\n"
        var manuscript = WritingDocument(id: WritingDocumentID(), title: "본편", body: manuscriptBody, kind: .manuscript)
        var note = WritingDocument(id: WritingDocumentID(), title: "설정집", body: noteBody, kind: .note)
        var project = WritingProject(id: WritingProjectID(), title: "장편", mode: .fiction, documents: [manuscript, note])
        let snapshot = ProjectDocumentSnapshot(
            identity: .init(key: .init(projectID: project.id, documentID: manuscript.id), generation: 1),
            title: manuscript.title,
            source: manuscript.source,
            kind: .manuscript,
            mode: .fiction
        )
        let savedHead = try ManuscriptVersion.capture(snapshot, label: "초고")
        project.userData[savedHead.userDataKey] = try JSONEncoder().encode(savedHead)
        var branchState = ManuscriptBranchState(documentID: manuscript.id)
        branchState.recordCommit(savedHead)
        project.userData[ManuscriptBranchState.userDataKey(for: manuscript.id)] = try JSONEncoder().encode(branchState)

        manuscript.source = try manuscript.source.replacing(NSRange(location: 6, length: 1), with: "겨")
        let unmaterializedNote = try note.source.replacing(NSRange(location: 0, length: 1), with: "[")
        note.source = unmaterializedNote
        project.documents = [manuscript, note]

        let brief = try XCTUnwrap(ManuscriptResumeBrief.build(for: manuscript.id, in: project, cursorOffset: 20))
        XCTAssertTrue(brief.hasUnsavedVersionChanges)
        XCTAssertEqual(brief.linkedNotes, ["마지막 메모", "첫 번째 메모"])
        XCTAssertEqual(project.documents[0].source.materializationCount, 0,
                       "Equal-length manuscript edits must not materialize the full rope when checking version diff")
        XCTAssertEqual(project.documents[1].source.materializationCount, 0,
                       "Scanning linked notes must stream rope chunks without joining the whole note")
    }

    func testRestyleAndResizeDoNotPoisonIncrementalTypingFastPath() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction)
        defer { h.close() }
        let body = "# 1장\n\n" + String(repeating: "여름밤 내내 이웃집에서 음악이 흘러나왔다. 정원에서 사람들은 이야기를 나누었다.\n\n", count: 2_500)
        h.fixture.session.updateSelectedDocumentBody(body)
        let editor = try await h.editor()
        h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 400, length: 0))

        // Simulate Dark/Light theme switch restyle and window resize
        let rebuildsBefore = editor.serialCacheRebuildCount
        editor.palette = .dark
        editor.restyleAll()
        XCTAssertNil(editor.serialDirtyRange,
                     "Theme restyle must not mark the entire document dirty for serialization")
        XCTAssertNil(editor.writingProjectionCapture.currentDirtyRange,
                     "Theme restyle must not leave a full-document dirty range in WritingEditorProjectionCapture")

        editor.setFrameSize(NSSize(width: 920, height: 640))
        editor.setFrameSize(NSSize(width: 840, height: 640))

        // Now type Hangul at a distant paragraph and verify incremental O(1) path stays active
        editor.setSelectedRange(NSRange(location: 50_000, length: 0))
        h.window.testUndo.beginUndoGrouping()
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.markedRange())
        editor.insertText("한", replacementRange: editor.markedRange())
        h.window.testUndo.endUndoGrouping()

        XCTAssertEqual(editor.serialCacheRebuildCount, rebuildsBefore,
                       "Typing after theme switch and window resize must use incremental single-paragraph serialization, not a full rebuild")
        XCTAssertNil(editor.writingProjectionCapture.currentDirtyRange,
                     "WritingEditorProjectionCapture must clear its dirty range after binding")
    }

    func testWorkspaceInputComparison() async throws {
        guard ProcessInfo.processInfo.environment["PURLORY_INPUT_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in workspace input measurement")
        }
        let h = try await FramedWorkspaceHarness(mode: .fiction)
        defer { h.close() }
        _ = try XCTUnwrap(h.fixture.session.createDocument(title: "Synthetic long note", kind: .note))
        for size in [10_000, 237_000, 1_000_000] {
            let line = "여름밤 내내 이웃집에서 음악이 흘러나왔다. 정원에서 사람들은 이야기를 나누었다.\n\n"
            h.fixture.session.updateSelectedDocumentBody("# 합성 자료\n" + String(String(repeating: line, count: size / line.count + 1).prefix(size)))
            let editor = try await h.editor()
            h.window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: size / 2, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            await h.layout()
            var input: [Double] = [], settled: [Double] = []
            for i in 0..<40 {
                let start = DispatchTime.now().uptimeNanoseconds
                h.window.testUndo.beginUndoGrouping()
                input.append(elapsed {
                    if i % 4 == 0 { editor.insertText("가", replacementRange: editor.selectedRange()) }
                    else { editor.setMarkedText(i % 4 == 1 ? "ㅎ" : i % 4 == 2 ? "하" : "한",
                                               selectedRange: NSRange(location: 1, length: 0),
                                               replacementRange: NSRange(location: NSNotFound, length: 0)) }
                })
                h.window.testUndo.endUndoGrouping()
                await h.layout()
                editor.displayIfNeeded()
                settled.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            editor.unmarkText()
            print("WORKSPACE \(size) input \(stats(input)) settled \(stats(settled))")
        }
    }

    func testNativeInputComparison() throws {
        guard ProcessInfo.processInfo.environment["PURLORY_INPUT_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in native input measurement")
        }
        for size in [10_000, 100_000, 300_000] {
            let line = "여름밤 내내 이웃집에서 음악이 흘러나왔다. 정원에서 사람들은 이야기를 나누었다. "
            let body = String(String(repeating: line, count: size / line.count + 1).prefix(size))
            let block = makeView(block: true) as! BlockTextView
            block.textStorage?.delegate = block
            let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
            var generation: UInt64 = 1
            block.writingRuntimeIdentityProvider = { .init(key: key, generation: generation) }
            block.load(markdown: body)
            var source = block.serializedSource()
            let owner = PurloryBlockEditor(source: Binding(get: { source }, set: { source = $0; generation += 1 }),
                                          documentIdentity: .project(key))
            let coordinator = owner.makeCoordinator()
            block.delegate = coordinator
            let plain = makeView(block: false)
            plain.textStorage?.setAttributedString(block.textStorage!)
            for (name, view) in [("native", plain), ("purlory", block)] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let scroll = NSScrollView(frame: window.contentView!.bounds)
                view.setFrameSize(NSSize(width: 760, height: 600))
                view.isVerticallyResizable = true
                view.isHorizontallyResizable = false
                view.textContainerInset = NSSize(width: 48, height: 60)
                view.isAutomaticSpellingCorrectionEnabled = false
                view.isAutomaticTextReplacementEnabled = false
                scroll.documentView = view
                window.contentView = scroll
                window.makeFirstResponder(view)
                view.layoutManager!.ensureLayout(for: view.textContainer!)
                view.setSelectedRange(NSRange(location: size / 2, length: 0))
                view.scrollRangeToVisible(view.selectedRange())
                var input: [Double] = [], overlay: [Double] = [], layout: [Double] = []
                for i in 0..<40 {
                    input.append(elapsed {
                        if i % 4 == 0 { view.insertText("가", replacementRange: view.selectedRange()) }
                        else {
                            view.setMarkedText(i % 4 == 1 ? "ㅎ" : i % 4 == 2 ? "하" : "한",
                                               selectedRange: NSRange(location: 1, length: 0),
                                               replacementRange: NSRange(location: NSNotFound, length: 0))
                        }
                    })
                    overlay.append(elapsed { (view as? BlockTextView)?.refreshActiveLineHighlight() })
                    layout.append(elapsed {
                        view.layoutManager!.ensureLayout(forBoundingRect: scroll.contentView.bounds,
                                                       in: view.textContainer!)
                    })
                }
                view.unmarkText()
                print("INPUT \(size) \(name) input \(stats(input)) overlay \(stats(overlay)) layout \(stats(layout))")
                window.contentView = nil
                window.close()
            }
            XCTAssertEqual(source.string, block.serialize())
        }
    }

    private func makeView(block: Bool) -> NSTextView {
        let storage = NSTextStorage()
        let manager = block ? PurloryLayoutManager() : NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 664, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        return block ? BlockTextView(frame: .zero, textContainer: container)
            : NSTextView(frame: .zero, textContainer: container)
    }
    private func elapsed(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private func stats(_ values: [Double]) -> String {
        let sorted = values.sorted()
        return String(format: "p50 %.3f p95 %.3f ms", sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)])
    }
}

private final class GlyphGenerationCounter: NSObject, NSLayoutManagerDelegate {
    var generated = 0
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        generated += glyphRange.length
        return 0
    }
}
