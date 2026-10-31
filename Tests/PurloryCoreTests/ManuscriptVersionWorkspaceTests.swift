import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class ManuscriptVersionWorkspaceTests: XCTestCase {
    func testRestoreWithoutAnUndoOwnerRefusesToMutateTheManuscript() async throws {
        let root = try temporaryProjectRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ProjectSession(store: ProjectStore(root: root), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await session.saveAndActivate(projectFixture())
        let version = try ManuscriptVersion.capture(XCTUnwrap(session.selectedDocumentSnapshot))
        session.updateSelectedDocumentBody("Changed")
        let comparison = try version.comparison(with: XCTUnwrap(session.selectedDocumentSnapshot))
        XCTAssertThrowsError(try ManuscriptVersionActions.restore(comparison, session: session, requests: ProjectEditorRequests()))
        XCTAssertEqual(session.selectedDocument?.body, "Changed")
    }

    func testCaptureSurvivesDerivedPurgeAndVerifiedBackupWithOriginalAssets() async throws {
        let root = try temporaryProjectRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        var project = projectFixture(); project.documents[0].body = "**원문🙂** $x$\n\n![](images/a.png)\n"
        try await session.saveAndActivate(project)
        try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
        let version = try await ManuscriptVersionActions.capture(session: session, requests: ProjectEditorRequests(), label: "초고")
        session.updateSelectedDocumentBody("바뀐 원고"); try await session.saveNow()
        try await store.writeIntelligence(Data("derived".utf8), projectID: project.id, documentID: version.documentID)
        try await store.removeIntelligence(projectID: project.id, documentID: version.documentID)
        let loaded = try await store.load(id: project.id)
        XCTAssertEqual(try ManuscriptVersion.list(in: loaded.userData, documentID: version.documentID), [version])
        let backup = try await store.previousBackup(id: project.id)
        let copy = try await store.prepareBackupRestore(backup)
        XCTAssertNotEqual(copy.id, project.id)
        XCTAssertEqual(try ManuscriptVersion.list(in: copy.userData, documentID: version.documentID), [version])
        let assets = try await store.assetCatalog(id: copy.id)
        var exported = copy.documents[0]; exported.body = version.text
        let destination = root.appendingPathComponent("saved.md")
        let report = try MarkdownExporter.export(exported, assets: assets, to: destination)
        XCTAssertEqual(report.copiedAssets, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), version.text)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("images/a.png")), Data([1, 2, 3]))
    }
    func testRestoreSynchronizesNativeSourceAndUndoAndRejectsStaleRuntimeAndIME() async throws {
        let root = try temporaryProjectRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ProjectSession(store: ProjectStore(root: root), defaults: UserDefaults(suiteName: UUID().uuidString)!, autosaveDelay: .seconds(3600))
        var project = projectFixture(); project.documents[0].body = "**이전🙂**\n\n원문\n"
        try await session.saveAndActivate(project)
        let requests = ProjectEditorRequests()
        let version = try await ManuscriptVersionActions.capture(session: session, requests: requests)
        let changed = "**수정🙂**\n\n원문\n"
        session.updateSelectedDocumentBody(changed)
        let source = try XCTUnwrap(session.selectedDocumentSnapshot)
        let comparison = try version.comparison(with: source)
        let editor = BlockTextView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        let undo = UndoManager(); undo.groupsByEvent = false; editor.documentUndoManager = undo
        editor.load(markdown: changed); editor.setSelectedRange(NSRange(location: 1, length: 0))
        requests.register(editor, for: source.identity.key)
        try ManuscriptVersionActions.restore(comparison, change: 0, session: session, requests: requests)
        XCTAssertEqual(session.selectedDocument?.body, version.text)
        XCTAssertEqual(editor.serialize(), version.text)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(undo.canUndo); undo.undo()
        XCTAssertEqual(session.selectedDocument?.body, changed); XCTAssertEqual(editor.serialize(), changed)
        undo.redo(); XCTAssertEqual(editor.serialize(), version.text)
        XCTAssertThrowsError(try ManuscriptVersionActions.restore(comparison, session: session, requests: requests))
        session.updateSelectedDocumentBody(changed); editor.load(markdown: changed)
        let fresh = try version.comparison(with: XCTUnwrap(session.selectedDocumentSnapshot))
        undo.beginUndoGrouping()
        editor.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertThrowsError(try ManuscriptVersionActions.restore(fresh, session: session, requests: requests))
        XCTAssertEqual(session.selectedDocument?.body, changed)
        editor.unmarkText()
        undo.endUndoGrouping()
    }
}
