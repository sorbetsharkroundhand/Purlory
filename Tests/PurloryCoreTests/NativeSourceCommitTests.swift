import AppKit
import SwiftUI
import XCTest
@testable import PurloryFoundation
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class NativeSourceCommitTests: XCTestCase {
    func testQueuedBindingSnapshotCannotReplaceNewerNativeSourceOrRetiredOwner() async throws {
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let original = DocumentSource("Original")
        var live: DocumentSource? = original
        var frame = 0
        // A SwiftUI update can carry the value captured before the latest native key.
        let queued = Binding<DocumentSource>(get: { original }, set: { live = $0 })
        func view() -> PurloryBlockEditor {
            PurloryBlockEditor(source: queued, currentSource: { live }, documentIdentity: .project(key), focusRequest: frame)
        }
        let host = NSHostingView(rootView: view())
        let window = FramedWorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.testUndo.groupsByEvent = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func layout() async { for _ in 0..<10 { host.layoutSubtreeIfNeeded(); await Task.yield() } }
        func find(_ view: NSView) -> BlockTextView? { (view as? BlockTextView) ?? view.subviews.compactMap(find).first }
        await layout()
        let editor = try XCTUnwrap(find(host)), resets = editor.writingProjectionCapture.resetCount
        for (index, character) in "abc".enumerated() {
            window.testUndo.beginUndoGrouping()
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            window.testUndo.endUndoGrouping()
            frame += 1; host.rootView = view(); await layout()
            XCTAssertEqual(editor.string, String("abc".prefix(index + 1)) + "Original")
            XCTAssertEqual(editor.selectedRange().location, index + 1)
            XCTAssertEqual(editor.writingProjectionCapture.resetCount, resets)
        }
        live = DocumentSource("External")
        frame += 1; host.rootView = view(); await layout()
        XCTAssertEqual(editor.string, "External", "A proved external replacement must still load")
        live = nil
        frame += 1; host.rootView = view(); await layout()
        XCTAssertEqual(editor.string, "External")
        XCTAssertFalse(editor.isEditable, "Retired authority cannot fall back to a queued binding")
    }

    func testRapidMountedTypingPreservesCharacterOrderAndCaretAcrossFrameUpdates() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let editor = try await h.editor()
        h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let original = editor.string, resets = editor.writingProjectionCapture.resetCount
        let input = "edited-smoke3B28A632EDFE45478BB9C2665A81A440"
        var prefix = ""
        for character in input {
            h.window.testUndo.beginUndoGrouping()
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            h.window.testUndo.endUndoGrouping()
            prefix.append(character)
            try await Task.sleep(for: .milliseconds(8))
            await h.layout()
            XCTAssertEqual(editor.string, prefix + original)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: prefix.utf16.count, length: 0))
            XCTAssertEqual(editor.writingProjectionCapture.resetCount, resets)
        }
    }

    func testMountedProjectEditorKeepsNativeAuthorityAcrossLazyBindingUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Purlory-source-mounted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: ProjectStore(root: root), defaults: defaults, autosaveDelay: .seconds(3600))
        let document = WritingDocument(id: WritingDocumentID(), title: "Draft", body: "# Heading\nOriginal prose.", kind: .manuscript)
        try await session.saveAndActivate(WritingProject(id: WritingProjectID(), title: "Source", mode: .general, documents: [document]))
        let settings = CompletionSettings(defaults: defaults)
        settings.autocompleteEnabled = false
        let completion = CompletionController(settings: settings)
        let bridge = ProjectEditorBridge()
        session.documentDidChange = { bridge.noteSnapshot($0) }
        let host = NSHostingView(rootView: EditorPane(projectSession: session, editorRequests: ProjectEditorRequests(),
            completion: completion, settings: settings, theme: .light, editorBridge: bridge,
            positionStore: WritingPositionStore(defaults: defaults), showsChrome: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let editor = try XCTUnwrap(bridge.editor)
        let resets = editor.writingProjectionCapture.resetCount
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" Added.", replacementRange: editor.selectedRange())
        let source = try XCTUnwrap(session.selectedDocument?.source)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        XCTAssertEqual(source.materializationCount, 0)
        XCTAssertEqual(editor.writingProjectionCapture.resetCount, resets, "The source binding reloaded an accepted native edit")
        XCTAssertEqual(editor.writingProjectionCapture.mappedIdentity, session.runtimeIdentity)
        XCTAssertEqual(source.string, "# Heading\nOriginal prose. Added.")
        editor.undoManager?.undo()
        XCTAssertEqual(session.selectedDocument?.body, document.body)
    }

    func testBackgroundConsumerCallbacksDoNotMaterializeAcceptedSource() throws {
        let suite = "Purlory-source-consumers-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults)
        settings.autocompleteEnabled = false
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        var snapshot = ProjectDocumentSnapshot(identity: .init(key: key, generation: 1), title: "Draft",
            body: "# First\nThe door opened.", kind: .manuscript, mode: .fiction)
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        indexer.attach(documentProvider: { snapshot })
        indexer.originalNameAnchorsEnabled = true
        defer { indexer.shutdown() }
        indexer.noteDocumentChange(snapshot)
        let source = try snapshot.source.replacing(NSRange(location: snapshot.source.utf16Length, length: 0), with: " Again.")
        snapshot = ProjectDocumentSnapshot(identity: .init(key: key, generation: 2), title: "Draft",
            source: source, kind: .manuscript, mode: .fiction)
        indexer.noteDocumentChange(snapshot)
        XCTAssertEqual(source.materializationCount, 0, "The synchronous document callback joined the manuscript")
    }

    func testOrdinaryNativeEditsPublishOwnedSourcesWithoutJoiningMarkdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Purlory-source-commit-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        let body = (0..<2000).map { "문단 \($0)" }.joined(separator: "\n")
        let document = WritingDocument(id: WritingDocumentID(), title: "Draft", body: body, kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Source", mode: .general, documents: [document])
        try await session.saveAndActivate(project)
        let key = try XCTUnwrap(session.runtimeIdentity?.key), epoch = session.activationEpoch
        let binding = Binding<DocumentSource>(get: { session.selectedDocument!.source }, set: {
            session.updateDocumentSource($0, for: key, activationEpoch: epoch)
        })
        let parent = PurloryBlockEditor(source: binding, documentIdentity: .project(key),
            positionStore: WritingPositionStore(defaults: defaults))
        let coordinator = PurloryBlockEditor.Coordinator(parent)
        coordinator.loadedDocumentIdentity = .project(key)
        let editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        editor.textStorage?.delegate = editor
        editor.writingDocumentIdentity = .project(key)
        editor.writingRuntimeIdentityProvider = { session.runtimeIdentity }
        editor.load(markdown: body)
        coordinator.lastSyncedSource = session.selectedDocument?.source
        editor.delegate = coordinator
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertText("가", replacementRange: editor.selectedRange())
        let first = try XCTUnwrap(session.selectedDocumentSnapshot)
        XCTAssertEqual(first.source.materializationCount, 0)
        XCTAssertEqual(first.source.utf16Length, body.utf16.count + 1)
        XCTAssertNotEqual(first.identity.generation, 0)
        editor.insertText("나", replacementRange: editor.selectedRange())
        let second = try XCTUnwrap(session.selectedDocumentSnapshot)
        XCTAssertGreaterThan(second.identity.generation, first.identity.generation)
        XCTAssertEqual(second.source.materializationCount, 0)
        XCTAssertEqual(first.source.materializationCount, 0)
        XCTAssertLessThan(second.source.lastMutationVisits, 256)

        // Termination cannot depend on the autosave timer or the native view staying alive.
        try await session.flushForTermination()
        let reopened = try await store.load(id: project.id)
        let expected = (body as NSString).replacingCharacters(in: NSRange(location: 2, length: 0), with: "가나")
        XCTAssertEqual(reopened.documents[0].body, expected)
        XCTAssertEqual(first.body, (body as NSString).replacingCharacters(in: NSRange(location: 2, length: 0), with: "가"))
    }

    func testSourceCommitRejectsRetiredActivationAndDoesNotMaterializeRejectedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Purlory-source-epoch-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: ProjectStore(root: root), defaults: defaults, autosaveDelay: .seconds(3600))
        let a = WritingDocument(id: WritingDocumentID(), title: "A", body: "A", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Source", mode: .general, documents: [a])
        try await session.saveAndActivate(project)
        let key = try XCTUnwrap(session.runtimeIdentity?.key), retiredEpoch = session.activationEpoch
        try await session.activateProject(id: project.id)
        let source = DocumentSource(chunks: ["stale"])
        session.updateDocumentSource(source, for: key, activationEpoch: retiredEpoch)
        XCTAssertEqual(session.selectedDocument?.body, "A")
        XCTAssertEqual(source.materializationCount, 0)
    }

    func testDocumentCodableKeepsTheExistingBodyField() throws {
        var document = WritingDocument(id: WritingDocumentID(), title: "Draft", body: "e\u{301}\r\n", kind: .manuscript)
        document.source = try document.source.replacing(NSRange(location: 0, length: 0), with: "한")
        let data = try JSONEncoder().encode(document)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["body"])
        XCTAssertNil(object["source"])
        let decoded = try JSONDecoder().decode(WritingDocument.self, from: data)
        XCTAssertEqual(Array(decoded.body.utf8), Array("한e\u{301}\r\n".utf8))
    }
}
