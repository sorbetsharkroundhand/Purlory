import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore

@MainActor
final class ProjectEditorTransitionTests: XCTestCase {
    func testFirstProjectEditorMountRestoresPersistedCompositeSelection() async throws {
        let suite = "Purlory-project-position-mount-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ProjectDocumentKey(
            projectID: WritingProjectID(), documentID: WritingDocumentID())
        let body = (0..<200)
            .map { "\($0) long project paragraph keeps the restored caret below the first screen." }
            .joined(separator: "\n")
        let selected = NSRange(location: 8_000, length: 5)
        let seed = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        seed.record(
            location: selected.location, selectionLength: selected.length, body: body, for: key)
        seed.persistNow()
        let reopened = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        let window = LegacyUndoWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PurloryBlockEditor(
            text: .constant(body), documentIdentity: .project(key), positionStore: reopened))
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let editor = try XCTUnwrap(findEditor(host))

        XCTAssertEqual(editor.selectedRange(), selected)
        XCTAssertGreaterThan(
            try XCTUnwrap(editor.enclosingScrollView).contentView.bounds.origin.y, 0)
    }

    func testSelectionOnlyMovePersistsThroughRealTerminationPath() async throws {
        let harness = try await ProjectPositionViewHarness()
        defer { harness.close() }
        let editor = try await harness.editor()
        let selected = NSRange(location: 3, length: 5)
        editor.setSelectedRange(selected)
        let termination = ProjectTerminationCoordinator(
            session: harness.fixture.session,
            persistPositions: { harness.positionStore.persistNow() },
            shutdown: {}, drain: {})

        let terminationResult = await termination.prepareForTermination()
        XCTAssertEqual(terminationResult, .terminateNow)

        let reopened = WritingPositionStore(
            defaults: harness.fixture.defaults, persistDelay: .seconds(3600))
        let key = ProjectDocumentKey(
            projectID: harness.fixture.project.id,
            documentID: harness.fixture.project.documents[0].id)
        let restored = reopened.restore(in: "original project", for: key)
        XCTAssertEqual(restored?.location, selected.location)
        XCTAssertEqual(restored?.selectionLength, selected.length)
    }

    func testSelectionOnlyMovePersistsAcrossContentViewProjectSwitch() async throws {
        let harness = try await ProjectPositionViewHarness()
        defer { harness.close() }
        let original = harness.fixture.project.documents[0]
        let destination = WritingProject(
            id: WritingProjectID(), title: "Destination", mode: .general,
            documents: [WritingDocument(
                id: WritingDocumentID(), title: "Other", body: "other project",
                kind: .manuscript)])
        try await harness.fixture.store.save(destination)
        let editor = try await harness.editor()
        let selected = NSRange(location: 4, length: 6)
        editor.setSelectedRange(selected)

        try await harness.fixture.session.activateProject(id: destination.id)
        await harness.layout()
        harness.positionStore.persistNow()

        let reopened = WritingPositionStore(
            defaults: harness.fixture.defaults, persistDelay: .seconds(3600))
        let key = ProjectDocumentKey(
            projectID: harness.fixture.project.id, documentID: original.id)
        let restored = reopened.restore(in: original.body, for: key)
        XCTAssertEqual(restored?.location, selected.location)
        XCTAssertEqual(restored?.selectionLength, selected.length)
    }

    // Exercises the real ContentView callback and EditorPane binding while durable I/O is held.
    func testProjectSaveCommitsIMEAndFencesNativeEditorUntilFailedSaveRestoresIt() async throws {
        try await verifyProjectTransition(fails: true, suspending: false)
    }

    func testSuccessfulProjectTerminationKeepsEditorFencedAndPersistsCommittedIME() async throws {
        try await verifyProjectTransition(fails: false, suspending: false)
    }

    func testFailedProjectSuspensionRestoresNativeEditingAndAcceptedIME() async throws {
        try await verifyProjectTransition(fails: true, suspending: true)
    }

    private func verifyProjectTransition(fails: Bool, suspending: Bool) async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let writing = expectation(description: "Real project save is suspended")
        let files = SuspendedEditorProjectFiles(fails: fails, started: { writing.fulfill() })
        defer { files.release() }
        let store = ProjectStore(root: fixture.root.appendingPathComponent("Projects"), fileSystem: files)
        let session = ProjectSession(store: store, defaults: fixture.defaults, autosaveDelay: .seconds(3600))
        try await session.bootstrap()
        let settings = CompletionSettings(defaults: fixture.defaults)
        let completion = CompletionController(settings: settings)
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        let requests = ProjectEditorRequests()
        let window = LegacyUndoWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testUndo.groupsByEvent = false
        let host = NSHostingView(rootView: ContentView(projectSession: session,
            startup: ProjectStartupCoordinator(session: session, store: store, storageLocation: .init(rootDirectory: fixture.legacyRoot)), editorRequests: requests,
            completion: completion, indexer: indexer, livingMargin: LivingMarginModel(),
            firstRunFlow: FirstRunFlow(session: session, store: store, editorRequests: requests)))
        window.contentView = host
        defer {
            window.testUndo.removeAllActions()
            window.contentView = nil
            window.close()
            completion.shutdown()
            indexer.shutdown()
        }
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let editor = try XCTUnwrap(findEditor(host))
        window.makeFirstResponder(editor)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(editor.isEditable, "Ordinary ready project editing must remain enabled")
        let manager = try XCTUnwrap(editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        editor.insertText("!", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        manager.endUndoGrouping()
        XCTAssertEqual(session.selectedDocument?.body, "original project!")
        manager.beginUndoGrouping()
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let accepted = editor.serialize()
        let selection = editor.selectedRange()
        let transition = try XCTUnwrap(session.willTransition)
        session.willTransition = {
            transition()
            XCTAssertEqual(session.selectedDocument?.body, accepted, "IME must publish before mutation acceptance closes")
            XCTAssertFalse(editor.isEditable, "Fence must close synchronously before any save await")
        }
        let save = Task {
            if suspending { try await session.suspend() }
            else { try await session.flushForTermination() }
        }
        await fulfillment(of: [writing], timeout: 3)
        manager.endUndoGrouping()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertFalse(editor.isEditable)
        for _ in 0..<5 { requests.focusEditor(); host.layoutSubtreeIfNeeded(); await Task.yield() }
        XCTAssertFalse(editor.isEditable, "SwiftUI must not reopen the editor while persistence is pending")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(window.firstResponder === editor)
        files.release()
        do {
            try await save.value
            XCTAssertFalse(fails, "Expected injected durable write failure")
        } catch {
            XCTAssertTrue(fails, "Unexpected save error: \(error)")
        }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        XCTAssertEqual(editor.isEditable, fails)
        XCTAssertEqual(editor.serialize(), accepted)
        XCTAssertEqual(session.selectedDocument?.body, accepted)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(manager.canUndo)
        if fails {
            manager.undo()
            XCTAssertEqual(session.selectedDocument?.body, editor.serialize())
            XCTAssertEqual(editor.serialize(), "original project!")
        } else {
            let durable = try await store.activeProject()
            XCTAssertEqual(durable?.documents[0].body, accepted)
        }
    }

    private func findEditor(_ view: NSView) -> BlockTextView? {
        if let editor = view as? BlockTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor($0) }.first
    }
}

@MainActor
private final class ProjectPositionViewHarness {
    let fixture: LegacyBoundaryFixture
    let positionStore: WritingPositionStore
    let legacyWorkspace: LegacyWorkspaceController
    let completion: CompletionController
    let indexer: BackgroundIndexer
    let window: LegacyUndoWindow
    let host: NSHostingView<ContentView>

    init() async throws {
        fixture = try await LegacyBoundaryFixture()
        positionStore = WritingPositionStore(
            defaults: fixture.defaults, persistDelay: .seconds(3600))
        legacyWorkspace = LegacyWorkspaceController(session: fixture.session)
        let settings = CompletionSettings(defaults: fixture.defaults)
        completion = CompletionController(settings: settings)
        indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        let requests = ProjectEditorRequests()
        window = LegacyUndoWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: ContentView(
            projectSession: fixture.session,
            startup: ProjectStartupCoordinator(session: fixture.session, store: fixture.store, storageLocation: .init(rootDirectory: fixture.legacyRoot)),
            editorRequests: requests,
            completion: completion,
            indexer: indexer,
            livingMargin: LivingMarginModel(),
            firstRunFlow: FirstRunFlow(
                session: fixture.session, store: fixture.store, editorRequests: requests),
            positionStore: positionStore))
        window.contentView = host
        await layout()
    }

    func layout() async {
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); await Task.yield() }
    }

    func editor() async throws -> BlockTextView {
        await layout()
        return try XCTUnwrap(findEditor(in: host))
    }

    func close() {
        window.testUndo.removeAllActions()
        window.contentView = nil
        window.close()
        completion.shutdown()
        indexer.shutdown()
        fixture.cleanUp()
    }

    private func findEditor(in view: NSView) -> BlockTextView? {
        if let editor = view as? BlockTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }
}

private final class SuspendedEditorProjectFiles: ProjectFileSystem, @unchecked Sendable {
    private let real = LocalProjectFileSystem()
    private let condition = NSCondition()
    private var released = false
    private let fails: Bool
    private let started: @Sendable () -> Void

    init(fails: Bool, started: @escaping @Sendable () -> Void) {
        self.fails = fails
        self.started = started
    }
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func read(_ url: URL) throws -> Data { try real.read(url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws {
        guard url.path.contains("/Documents/") else { return try real.writeAtomically(data, to: url) }
        condition.lock()
        started()
        while !released { condition.wait() }
        condition.unlock()
        if fails { throw CocoaError(.fileWriteNoPermission) }
        try real.writeAtomically(data, to: url)
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
