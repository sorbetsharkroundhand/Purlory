@_spi(Benchmark) @testable import PurloryInference
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore

@MainActor
final class SourceNavigationTests: XCTestCase {
    func testRealWorkspaceJumpReturnRestoresDocumentSelectionScrollFocusAndUndo() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        let original = try await h.editor(), key = try XCTUnwrap(h.fixture.session.runtimeIdentity?.key)
        original.setSelectedRange(NSRange(location: 3000, length: 6))
        original.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 400))
        let point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session))
        let undo = try XCTUnwrap(original.undoManager)
        let body = original.serialize()
        let hit = try XCTUnwrap(SourceSearch.results(query: "needle", in:
            try XCTUnwrap(h.fixture.session.activeProject), origin: key.documentID,
            cursor: 0, scope: .project).last)

        XCTAssertTrue(h.requests.jump(to: hit, in: h.fixture.session))
        await h.layout()
        let destination = try await h.editor()
        XCTAssertEqual(h.fixture.session.selectedDocumentID, hit.documentID)
        XCTAssertEqual((destination.string as NSString).substring(with: destination.selectedRange()), "needle")
        XCTAssertTrue(h.requests.returnToWriting(in: h.fixture.session))
        await h.layout()
        let returned = try await h.editor()
        XCTAssertEqual(h.fixture.session.runtimeIdentity?.key, key)
        XCTAssertEqual(returned.selectedRange(), point.selection)
        XCTAssertEqual(returned.enclosingScrollView?.contentView.bounds.origin.y ?? -1, point.scrollOrigin.y, accuracy: 0.5)
        XCTAssertEqual(returned.serialize(), body)
        XCTAssertTrue(returned.undoManager === undo)
        XCTAssertTrue(h.window.firstResponder === returned)
    }

    func testSameDocumentDuplicatesMapThroughMarkdownAndReturnPreservesUndo() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let editor = try await h.editor()
        let manager = try XCTUnwrap(editor.undoManager)
        manager.beginUndoGrouping()
        editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        manager.endUndoGrouping()
        await h.layout()
        let point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session))
        let p = try XCTUnwrap(h.fixture.session.activeProject)
        let hits = try SourceSearch.results(query: "needle", in: p, origin: point.key.documentID, cursor: 0, scope: .here)
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(h.requests.jump(to: hits[1], in: h.fixture.session))
        await h.layout()
        XCTAssertEqual(editor.selectedRange().location, (editor.string as NSString).range(of: "needle", options: .backwards).location)
        XCTAssertTrue(h.requests.returnToWriting(in: h.fixture.session))
        await h.layout()
        XCTAssertEqual(editor.selectedRange(), point.selection)
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        XCTAssertFalse(editor.serialize().hasPrefix("!"))
    }

    func testMarkedTextAndEditedReturnTargetsCannotMoveSelection() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let view = try await h.editor(), p = try XCTUnwrap(h.fixture.session.activeProject)
        let hit = try XCTUnwrap(SourceSearch.results(query: "needle", in: p, origin: p.documents[0].id, cursor: 0, scope: .here).first)
        let manager = try XCTUnwrap(view.undoManager)
        manager.beginUndoGrouping()
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let selection = view.selectedRange()
        XCTAssertNil(h.requests.captureSourcePosition(in: h.fixture.session))
        XCTAssertFalse(view.applySourceNavigation(.passage(hit)))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.selectedRange(), selection)
        view.unmarkText(); view.didChangeText(); manager.endUndoGrouping(); await h.layout()
        let fresh = try XCTUnwrap(SourceSearch.results(query: "needle", in:
            try XCTUnwrap(h.fixture.session.activeProject), origin: p.documents[0].id, cursor: 0, scope: .here).first)
        XCTAssertTrue(h.requests.jump(to: fresh, in: h.fixture.session)); await h.layout()
        manager.beginUndoGrouping()
        view.insertText("changed", replacementRange: NSRange(location: 0, length: 0))
        manager.endUndoGrouping(); await h.layout()
        XCTAssertFalse(h.requests.returnToWriting(in: h.fixture.session))
        XCTAssertNotNil(h.requests.sourceNavigationError)
    }

    func testNativeRequestsRejectSameDocumentIDInAnotherProject() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let key = try XCTUnwrap(h.fixture.session.runtimeIdentity?.key)
        let hit = try XCTUnwrap(SourceSearch.results(query: "needle", in:
            try XCTUnwrap(h.fixture.session.activeProject), origin: key.documentID, cursor: 0, scope: .here).first)
        let jump = EditorSearchJump(documentID: hit.documentID, query: "needle", sequence: 1, source: .passage(hit))
        let other = EditorDocumentIdentity.project(ProjectDocumentKey(projectID: WritingProjectID(), documentID: key.documentID))
        let coordinator = PurloryBlockEditor(text: .constant(""), documentIdentity: other).makeCoordinator()
        XCTAssertNil(coordinator.consumeSearchJump(jump, for: other))
        let replacement = WritingProject(id: WritingProjectID(), title: "Other", mode: .general,
            documents: [WritingDocument(id: key.documentID, title: "Same ID", body: "needle", kind: .manuscript)])
        try await h.fixture.session.saveAndActivate(replacement); await h.layout()
        XCTAssertFalse(h.requests.jump(to: hit, in: h.fixture.session))
    }

    func testSourceCursorTracksInsideLongAndFormattedParagraphs() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody(String(repeating: "a", count: 4000) + "needle")
        await h.layout()
        let view = try await h.editor()
        view.setSelectedRange(NSRange(location: 3000, length: 0))
        XCTAssertEqual(h.requests.captureSourcePosition(in: h.fixture.session)?.sourceCursor, 3000)
        h.fixture.session.updateSelectedDocumentBody("# One\n**미나**가 간다.")
        await h.layout()
        view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(h.requests.captureSourcePosition(in: h.fixture.session)?.sourceCursor, 9)
    }

    func testSourceParagraphOffsetIncludesConsumedHeadingMarkers() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("# One\n😀 prose\n## Two\nneedle")
        await h.layout()
        let editor = try await h.editor()
        editor.setSelectedRange((editor.string as NSString).range(of: "needle"))
        let point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session))
        XCTAssertEqual(point.sourceCursor, 22)
    }
}

@MainActor
final class SourceNavigationHarness {
    let fixture: LegacyBoundaryFixture
    let requests = ProjectEditorRequests()
    let window: LegacyUndoWindow
    let host: NSView
    let completion: CompletionController
    let indexer: BackgroundIndexer
    init(short: Bool = false, mode: WritingMode = .general) async throws {
        fixture = try await LegacyBoundaryFixture(mode: mode)
        fixture.session.updateSelectedDocumentBody(short ? "# Here\nneedle and **needle**." :
            (0..<150).map { "Paragraph \($0) retains original writing selection and native scroll position." }.joined(separator: "\n"))
        if !short {
            _ = fixture.session.createDocument(title: "Source")
            fixture.session.updateSelectedDocumentBody("# Found\nA needle appears.")
            fixture.session.selectDocument(fixture.project.documents[0].id)
        }
        let settings = CompletionSettings(defaults: fixture.defaults)
        completion = CompletionController(settings: settings)
        indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        window = LegacyUndoWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testUndo.groupsByEvent = false
        host = NSHostingView(rootView: ContentView(projectSession: fixture.session,
            startup: ProjectStartupCoordinator(session: fixture.session, store: fixture.store, storageLocation: .init(rootDirectory: fixture.legacyRoot)), editorRequests: requests, completion: completion,
            indexer: indexer, livingMargin: LivingMarginModel(), firstRunFlow: FirstRunFlow(
                session: fixture.session, store: fixture.store, editorRequests: requests),
            positionStore: WritingPositionStore(defaults: fixture.defaults)).defaultAppStorage(fixture.defaults))
        window.contentView = host
        await layout()
    }
    func layout() async { for _ in 0..<25 { host.layoutSubtreeIfNeeded(); await Task.yield() } }
    func editor() async throws -> BlockTextView {
        await layout()
        if let key = fixture.session.runtimeIdentity?.key, let editor = requests.editor(for: key) { return editor }
        func find(_ v: NSView) -> BlockTextView? {
            (v as? BlockTextView) ?? v.subviews.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(host))
    }
    func close() {
        window.testUndo.removeAllActions(); window.contentView = nil; window.close()
        completion.shutdown(); indexer.shutdown(); fixture.cleanUp()
    }
}
