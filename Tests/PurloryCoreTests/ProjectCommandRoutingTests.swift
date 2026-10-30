@testable import PurloryIntelligence
@testable import PurloryStorage
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ProjectCommandRoutingTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-ProjectCommands-\(UUID().uuidString)", isDirectory: true)
    }

    private func defaults() -> (UserDefaults, String) {
        let name = "Purlory.ProjectCommandRoutingTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testNewDocumentCommandMutatesTheActiveSessionProject() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: ProjectStore(root: url), defaults: defaults)
        try await ProjectCreationCoordinator(session: session)
            .createProject(title: "Draft", mode: .general)
        let before = try XCTUnwrap(session.activeProject?.documents.count)

        ProjectCommandActions(session: session).newDocument(.note)

        XCTAssertEqual(session.activeProject?.documents.count, before + 1)
        XCTAssertEqual(session.selectedDocument?.kind, .note)
    }

    func testRenameAndTrashCommandsTargetOnlyTheSelectedProjectDocument() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: ProjectStore(root: url), defaults: defaults)
        try await ProjectCreationCoordinator(session: session)
            .createProject(title: "Draft", mode: .fiction)
        let originalID = try XCTUnwrap(session.selectedDocumentID)
        let actions = ProjectCommandActions(session: session)

        actions.renameDocument("Opening")
        actions.newDocument(.manuscript)
        let selectedID = try XCTUnwrap(session.selectedDocumentID)
        actions.trashDocument()

        XCTAssertEqual(
            session.activeProject?.documents.first(where: { $0.id == originalID })?.title,
            "Opening")
        XCTAssertTrue(session.activeProject?.trashedDocumentIDs.contains(selectedID) == true)
        XCTAssertEqual(session.selectedDocumentID, originalID)
    }

    func testSearchResultSelectionTargetsDocumentBeforeIssuingNeutralJump() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: ProjectStore(root: url), defaults: defaults)
        try await ProjectCreationCoordinator(session: session)
            .createProject(title: "Draft", mode: .general)
        let firstID = try XCTUnwrap(session.selectedDocumentID)
        let secondID = try XCTUnwrap(session.createDocument(title: "Second"))
        session.selectDocument(firstID)
        let projectID = try XCTUnwrap(session.activeProject?.id)
        let result = ProjectSearchResult(
            projectID: projectID,
            documentID: secondID,
            title: "Second",
            snippet: "A needle appears.",
            query: "needle")
        let requests = ProjectEditorRequests()

        requests.jump(to: result, in: session)

        XCTAssertEqual(session.selectedDocumentID, secondID)
        XCTAssertEqual(
            requests.searchJump,
            EditorSearchJump(documentID: secondID, query: "needle", sequence: 1))
        XCTAssertEqual(requests.editorFocusRequest, 1)
    }

    func testSaveCommandFlushesTheActiveSessionProject() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: url)
        let session = ProjectSession(
            store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await ProjectCreationCoordinator(session: session)
            .createProject(title: "Draft", mode: .general)
        session.updateSelectedDocumentBody("Saved through command")

        try await ProjectCommandActions(session: session).save()

        let projectID = try XCTUnwrap(session.activeProject?.id)
        let reopened = try await store.load(id: projectID)
        XCTAssertEqual(reopened.documents[0].body, "Saved through command")
    }

    func testSaveCommandCommitsPendingEditorTextBeforeSavingAndReopensEditing() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        fixture.session.willTransition = { fixture.session.updateSelectedDocumentBody("accepted composition 한") }
        try await ProjectCommandActions(session: fixture.session).save()
        let reopened = try await fixture.store.activeProject()
        XCTAssertEqual(reopened?.documents[0].body, "accepted composition 한")
        XCTAssertFalse(fixture.session.isTransitioning)
        XCTAssertTrue(fixture.session.isEditorEditable)
    }

    func testRecentProjectPickerRejectsMissingProjectWithoutLeavingCurrent() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: ProjectStore(root: url), defaults: defaults)
        try await ProjectCreationCoordinator(session: session)
            .createProject(title: "Current", mode: .general)
        let currentID = session.activeProject?.id

        do {
            try await session.activateProject(id: WritingProjectID())
            XCTFail("Missing project unexpectedly activated")
        } catch {}

        XCTAssertEqual(session.activeProject?.id, currentID)
        XCTAssertNotNil(session.lastErrorMessage)
    }
}
