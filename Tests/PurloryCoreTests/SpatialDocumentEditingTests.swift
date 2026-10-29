@testable import PurloryStorage
import AppKit
import XCTest
@testable import PurloryCore

@MainActor final class SpatialDocumentEditingTests: XCTestCase {
    func testInactiveDocumentBindingEditsItsCapturedKeyAndPersistsBothDocuments() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = fixture.project.documents[0], b = fixture.project.documents[1]
        let key = ProjectDocumentKey(projectID: fixture.project.id, documentID: a.id)
        fixture.session.selectDocument(b.id)
        fixture.session.updateDocumentBody("A edited", for: key)
        XCTAssertEqual(fixture.session.selectedDocumentID, b.id)
        XCTAssertEqual(fixture.session.selectedDocument?.body, b.body)
        XCTAssertEqual(fixture.session.document(a.id)?.body, "A edited")
        try await fixture.session.flush()
        let loaded = try await fixture.store.load(id: fixture.project.id)
        XCTAssertEqual(loaded.documents.map(\.body), ["A edited", b.body])
    }

    func testMultiDocumentTransactionIsAtomicAndRejectsStaleOrTrashedBodies() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let a = f.project.documents[0], b = f.project.documents[1]
        func edit(_ document: WritingDocument, expected: String, body: String) -> ProjectDocumentEdit {
            .init(key: .init(projectID: f.project.id, documentID: document.id), expectedBody: expected, body: body)
        }
        XCTAssertThrowsError(try f.session.applyDocumentEdits([
            edit(a, expected: a.body, body: ""), edit(b, expected: "stale", body: "bad")]))
        XCTAssertEqual(f.session.activeProject?.documents.map(\.body), [a.body, b.body])
        try f.session.applyDocumentEdits([edit(a, expected: a.body, body: ""), edit(b, expected: b.body, body: b.body + a.body)])
        XCTAssertEqual(f.session.activeProject?.documents.map(\.body), ["", b.body + a.body])
        let wrong = ProjectDocumentKey(projectID: WritingProjectID(), documentID: a.id)
        f.session.updateDocumentBody("wrong project", for: wrong)
        XCTAssertEqual(f.session.document(a.id)?.body, "")
        f.session.trashSelectedDocument()
        XCTAssertThrowsError(try f.session.applyDocumentEdits([edit(a, expected: "", body: "revived")]))
        XCTAssertTrue(f.session.activeProject!.trashedDocumentIDs.contains(a.id))
    }

    func testReorderKeepsSelectionAndRejectsMissingOrDuplicateDocuments() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ids = f.project.documents.map(\.id)
        f.session.reorderDocuments(ids.reversed(), projectID: f.project.id)
        XCTAssertEqual(f.session.activeProject?.documents.map(\.id), Array(ids.reversed()))
        XCTAssertEqual(f.session.selectedDocumentID, ids[0])
        f.session.reorderDocuments([ids[0], ids[0]], projectID: f.project.id)
        XCTAssertEqual(f.session.activeProject?.documents.map(\.id), Array(ids.reversed()))
    }

    func testOpeningOrSelectingDocumentDoesNotReorderProjectDocuments() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let originalOrder = f.project.documents.map(\.id)
        let b = originalOrder[1]

        // Selecting document B must NOT move document B to the front of project.documents
        f.session.selectDocument(b)
        XCTAssertEqual(f.session.activeProject?.documents.map(\.id), originalOrder)

        let controller = SpatialWorkspaceController(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        controller.configure(project: f.project, selected: originalOrder[0])
        controller.open(b)
        XCTAssertEqual(f.session.activeProject?.documents.map(\.id), originalOrder)
    }

    private func fixture() async throws -> (root: URL, store: ProjectStore, session: ProjectSession, project: WritingProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purlory-spatial-\(UUID())")
        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let project = WritingProject(id: WritingProjectID(), title: "Spatial transaction fixture", mode: .general,
            documents: [WritingDocument(id: WritingDocumentID(), title: "A", body: "**한글** $x$\n\n![](images/a.png)", kind: .manuscript),
                        WritingDocument(id: WritingDocumentID(), title: "B", body: "> B\n", kind: .manuscript)])
        try await session.saveAndActivate(project)
        return (root, store, session, project)
    }
}
