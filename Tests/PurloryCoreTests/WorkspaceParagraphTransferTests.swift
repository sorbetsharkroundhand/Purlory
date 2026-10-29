@testable import PurloryStorage
import AppKit
import XCTest
@testable import PurloryCore

@MainActor final class WorkspaceParagraphTransferTests: XCTestCase {
    func testRichParagraphMovesAtomicallyAndUndoRestoresBothOriginals() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let a = f.project.documents[0], b = f.project.documents[1]
        let chunk = "**한글🙂** $x$\n"
        let source = WorkspaceParagraphAnchor(key: .init(projectID: f.project.id, documentID: a.id),
            body: a.body, range: (a.body as NSString).range(of: chunk))
        let target = WorkspaceParagraphAnchor(key: .init(projectID: f.project.id, documentID: b.id),
            body: b.body, range: NSRange(location: 0, length: b.body.utf16.count))
        let undo = UndoManager(); undo.groupsByEvent = false
        try WorkspaceParagraphTransfer.perform(source: source, target: target, after: false, copy: false,
            session: f.session, requests: ProjectEditorRequests(), undoManager: undo)
        XCTAssertEqual(f.session.document(a.id)?.body, "First\n\n![](images/a.png)\n")
        XCTAssertEqual(f.session.document(b.id)?.body, chunk + b.body)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(f.session.activeProject?.documents.map(\.body), [a.body, b.body])
        undo.redo()
        XCTAssertEqual(f.session.document(b.id)?.body, chunk + b.body)
        try await f.session.flush()
        let saved = try await f.store.load(id: f.project.id)
        XCTAssertEqual(saved.documents.map(\.body), f.session.activeProject?.documents.map(\.body))
    }

    func testUndoRegistrationRetainsItsTransactionUntilTheActionIsRetired() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let a = f.project.documents[0], manager = UndoManager(); manager.groupsByEvent = false
        weak var transaction: WorkspaceDocumentTransaction?
        do {
            let created = try WorkspaceDocumentTransaction.perform([
                .init(key: .init(projectID: f.project.id, documentID: a.id), expectedBody: a.body, body: "New")],
                in: f.session, requests: ProjectEditorRequests(), undoManager: manager)
            transaction = created
        }
        XCTAssertNotNil(transaction, "NSUndoManager's target does not retain the command")
        manager.removeAllActions()
        XCTAssertNil(transaction)
    }

    func testOptionAndSoleParagraphCopyAndStaleDropPreservesText() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let a = f.project.documents[0], b = f.project.documents[1]
        let source = WorkspaceParagraphAnchor(key: .init(projectID: f.project.id, documentID: b.id), body: b.body,
            range: NSRange(location: 0, length: b.body.utf16.count))
        let target = WorkspaceParagraphAnchor(key: .init(projectID: f.project.id, documentID: a.id), body: a.body,
            range: NSRange(location: 0, length: 6))
        try WorkspaceParagraphTransfer.perform(source: source, target: target, after: true, copy: false,
            session: f.session, requests: ProjectEditorRequests())
        XCTAssertEqual(f.session.document(b.id)?.body, b.body, "A sole paragraph must copy")
        let before = f.session.activeProject
        XCTAssertThrowsError(try WorkspaceParagraphTransfer.perform(source: source, target: target, after: false, copy: true,
            session: f.session, requests: ProjectEditorRequests()))
        XCTAssertEqual(f.session.activeProject, before)
    }

    private func fixture() async throws -> (root: URL, store: ProjectStore, session: ProjectSession, project: WritingProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purlory-paragraph-transfer-\(UUID())")
        let store = ProjectStore(root: root), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let session = ProjectSession(store: store, defaults: defaults)
        let project = WritingProject(id: WritingProjectID(), title: "Paragraph fixture", mode: .general, documents: [
            WritingDocument(id: WritingDocumentID(), title: "Source", body: "First\n**한글🙂** $x$\n\n![](images/a.png)\n", kind: .manuscript),
            WritingDocument(id: WritingDocumentID(), title: "Target", body: "> Target\n", kind: .manuscript)])
        try await session.saveAndActivate(project)
        return (root, store, session, project)
    }
}
