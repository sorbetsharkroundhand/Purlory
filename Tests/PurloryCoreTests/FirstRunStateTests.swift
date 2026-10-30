@testable import PurloryIntelligence
@testable import PurloryStorage
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class FirstRunStateTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-FirstRun-\(UUID().uuidString)", isDirectory: true)
    }

    private func defaults() -> (UserDefaults, String) {
        let name = "Purlory.FirstRunTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testNoProjectShowsFirstRun() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProjectStore(root: url)

        let state = try await FirstRunStateResolver.resolve(using: store)

        XCTAssertEqual(state, .needsProject)
    }

    func testBlankProjectCreationNeedsNoCompletionModelAndCompletesFirstRun() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: url)
        let session = ProjectSession(store: store, defaults: defaults)
        let coordinator = ProjectCreationCoordinator(session: session)

        let result = try await coordinator.createProject(title: "", mode: .general)
        let active = try XCTUnwrap(session.activeProject)

        XCTAssertEqual(active.id, result.projectID)
        XCTAssertEqual(active.mode, .general)
        XCTAssertEqual(active.title, "Untitled")
        XCTAssertEqual(active.documents.count, 1)
        XCTAssertEqual(active.documents[0].id, result.documentID)
        XCTAssertEqual(active.documents[0].body, "")
        XCTAssertEqual(session.workspaceMode, .write)
        let stateAfterCreation = try await FirstRunStateResolver.resolve(using: store)
        XCTAssertEqual(stateAfterCreation, .ready(result.projectID))
    }

    func testExistingActiveProjectSkipsFirstRunAfterRelaunch() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: url)
        let session = ProjectSession(store: store, defaults: defaults)
        let result = try await ProjectCreationCoordinator(session: session)
            .createProject(title: "Novel", mode: .fiction)

        let relaunchedSession = ProjectSession(store: store, defaults: defaults)
        try await relaunchedSession.loadActiveProject()

        XCTAssertEqual(relaunchedSession.activeProject?.id, result.projectID)
        let stateAfterRelaunch = try await FirstRunStateResolver.resolve(using: store)
        XCTAssertEqual(stateAfterRelaunch, .ready(result.projectID))
    }

    func testContentRouteFollowsBootstrapAndProjectCreation() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: url)
        let session = ProjectSession(store: store, defaults: defaults)

        XCTAssertEqual(ContentViewRoute.resolve(session.phase), .progress)

        try await session.bootstrap()
        XCTAssertEqual(session.phase, .needsProject)
        XCTAssertEqual(ContentViewRoute.resolve(session.phase), .firstRun)

        let flow = FirstRunFlow(
            session: session,
            store: store,
            editorRequests: ProjectEditorRequests())
        try await flow.createProject(mode: .fiction)

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(ContentViewRoute.resolve(session.phase), .workspace)
    }

    func testCancelledProjectFolderPanelHasNoCoordinatorSideEffect() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: url)
        let session = ProjectSession(store: store, defaults: defaults)
        try await session.bootstrap()
        let flow = FirstRunFlow(
            session: session,
            store: store,
            editorRequests: ProjectEditorRequests())

        try await flow.importFolder(selection: nil)

        XCTAssertEqual(session.phase, .needsProject)
        XCTAssertNil(session.activeProject)
        let durableActive = try await store.activeProject()
        XCTAssertNil(durableActive)
    }

    func testNonReadyPhasesNeverRouteToWorkspace() {
        XCTAssertEqual(ContentViewRoute.resolve(.loading), .progress)
        XCTAssertEqual(ContentViewRoute.resolve(.suspended), .progress)
        XCTAssertEqual(ContentViewRoute.resolve(.failed), .error)
        XCTAssertEqual(ContentViewRoute.resolve(.needsProject), .firstRun)
        XCTAssertEqual(ContentViewRoute.resolve(.ready), .workspace)
    }
}
