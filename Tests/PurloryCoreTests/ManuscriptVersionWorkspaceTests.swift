import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryStorage
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
        let sha = try XCTUnwrap(version.gitCommitSHA)
        XCTAssertEqual(sha.count, 40)
        let gitReadback = try await store.readManuscriptGitBlob(projectID: project.id, commitSHA: sha, documentID: version.documentID)
        XCTAssertEqual(gitReadback, version.text)
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

    func testRealGitRepositoryBranchingMergingAndQuickNoteIsolation() async throws {
        let root = try temporaryProjectRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        var project = projectFixture()
        let manuscriptID = project.documents[0].id
        let noteID = project.documents[1].id
        project.documents[0].body = "1문단 시작\n\n2문단 유지\n\n3문단 결말\n"
        project.documents[1].body = "초기 메모\n"
        try await session.saveAndActivate(project)

        let requests = ProjectEditorRequests()
        let editor = BlockTextView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        let undo = UndoManager(); undo.groupsByEvent = false; editor.documentUndoManager = undo
        editor.load(markdown: project.documents[0].body)
        requests.register(editor, for: .init(projectID: project.id, documentID: manuscriptID))

        // Quick note appends to the .note document without switching away from the manuscript.
        let targetNoteID = try ManuscriptVersionActions.appendQuickNote("갑자기 떠오른 대사", session: session, requests: requests)
        XCTAssertEqual(targetNoteID, noteID)
        XCTAssertEqual(session.selectedDocumentID, manuscriptID)
        XCTAssertTrue(session.document(noteID)?.body.contains("갑자기 떠오른 대사") == true)

        // 1. Save initial manuscript version
        let baseVersion = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "1장 초고")
        XCTAssertEqual(baseVersion.branchName, "본편")
        XCTAssertNotNil(baseVersion.gitCommitSHA)

        // 2. Create a branch ("다른 결말") and edit the 3rd paragraph
        let branchStart = try await ManuscriptVersionActions.createBranch(name: "다른 결말", from: baseVersion, session: session, requests: requests, undoManager: undo)
        XCTAssertEqual(branchStart.branchName, "다른 결말")
        let altBody = "1문단 시작\n\n2문단 유지\n\n3문단 배드엔딩 결말\n"
        session.updateSelectedDocumentBody(altBody); editor.load(markdown: altBody)
        _ = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "배드엔딩 작성")

        // 3. Switch back to "본편" and edit the 1st paragraph
        try await ManuscriptVersionActions.switchBranch(to: "본편", session: session, requests: requests, undoManager: undo)
        XCTAssertEqual(session.selectedDocument?.body, "1문단 시작\n\n2문단 유지\n\n3문단 결말\n")
        let mainBody = "1문단 새로운 시작\n\n2문단 유지\n\n3문단 결말\n"
        session.updateSelectedDocumentBody(mainBody); editor.load(markdown: mainBody)
        _ = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "본편 도입부 수정")

        // 4. Merge "다른 결말" into "본편" (3-way merge combines 1st paragraph from "본편" and 3rd paragraph from "다른 결말")
        let mergeCommit = try await ManuscriptVersionActions.applyMerge(from: "다른 결말", session: session, requests: requests, undoManager: undo)
        XCTAssertEqual(mergeCommit.parentIDs.count, 2)
        XCTAssertEqual(session.selectedDocument?.body, "1문단 새로운 시작\n\n2문단 유지\n\n3문단 배드엔딩 결말\n")
        // Note document remains untouched by manuscript branch switches and merges
        XCTAssertTrue(session.document(noteID)?.body.contains("갑자기 떠오른 대사") == true)
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

    func testParagraphMoveAutomaticallyCapturesSafetyVersionSnapshot() async throws {
        let root = try temporaryProjectRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        var project = projectFixture()
        let manuscriptID = project.documents[0].id
        let originalBody = "첫 문단입니다.\n\n이동할 문단입니다.\n\n마지막 문단입니다.\n"
        project.documents[0].body = originalBody
        try await session.saveAndActivate(project)

        let key = ProjectDocumentKey(projectID: project.id, documentID: manuscriptID)
        let moveChunk = "이동할 문단입니다.\n"
        let sourceAnchor = WorkspaceParagraphAnchor(
            key: key,
            body: originalBody,
            range: (originalBody as NSString).range(of: moveChunk)
        )
        let targetAnchor = WorkspaceParagraphAnchor(
            key: key,
            body: originalBody,
            range: (originalBody as NSString).range(of: "첫 문단입니다.\n")
        )
        let undo = UndoManager(); undo.groupsByEvent = false
        try WorkspaceParagraphTransfer.perform(
            source: sourceAnchor,
            target: targetAnchor,
            after: false,
            copy: false,
            session: session,
            requests: ProjectEditorRequests(),
            undoManager: undo
        )

        let savedVersions = try ManuscriptVersion.list(in: XCTUnwrap(session.activeProject?.userData), documentID: manuscriptID)
        XCTAssertEqual(savedVersions.count, 1)
        XCTAssertEqual(savedVersions.first?.label, "문단 이동 전 자동 보관")
        XCTAssertEqual(savedVersions.first?.text, originalBody)
    }
}
