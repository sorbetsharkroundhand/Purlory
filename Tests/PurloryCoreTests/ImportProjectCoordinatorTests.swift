@testable import PurloryStorage
import Foundation
import XCTest
@testable import PurloryCore

@MainActor
final class ImportProjectCoordinatorTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-OnboardingImport-\(UUID().uuidString)", isDirectory: true)
    }

    private func defaults() -> (UserDefaults, String) {
        let name = "Purlory.OnboardingImportTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func writeLegacyFixture(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data(#"{"entries":[{"id":"00000000-0000-0000-0000-000000000201","title":"Draft","createdAt":"2026-09-01T00:00:00Z","body":"한글\r\n가\n![그림](images/a.png)\n","kind":"novel","characters":[]}],"activeID":"00000000-0000-0000-0000-000000000201","folders":[],"expandedFolderIDs":[]}"#.utf8)
        let source = root.appendingPathComponent("entries.json")
        try data.write(to: source)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("images"),
            withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("images/a.png"))
        return source
    }

    private func writeModernFixture(at root: URL) async throws -> (URL, WritingProject) {
        let store = ProjectStore(root: root)
        var project = projectFixture()
        project.mode = .fiction
        try await store.save(project)
        try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
        return (root.appendingPathComponent(project.id.rawValue.uuidString), project)
    }

    func testModernFolderActivatesManifestModeAndVerifiedAssets() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (source, project) = try await writeModernFixture(at: url.appendingPathComponent("development"))
        try Data("invalid legacy archive".utf8).write(to: source.appendingPathComponent("entries.json"))
        let original = try Data(contentsOf: source.appendingPathComponent("project.json"))
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: url.appendingPathComponent("container"))
        let session = ProjectSession(store: store, defaults: defaults)
        let id = try await ImportProjectCoordinator(store: store, session: session)
            .importFolder(from: source, legacyMode: .general)
        XCTAssertEqual(id, project.id)
        XCTAssertEqual(session.activeProject, project)
        XCTAssertEqual(session.assetCatalog?.data(for: "images/a.png"), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), original)
    }

    func testLegacyFolderRetainsSourceAndImages() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try writeLegacyFixture(at: url.appendingPathComponent("development"))
        let original = try Data(contentsOf: source)
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: url.appendingPathComponent("container"))
        let session = ProjectSession(store: store, defaults: defaults)
        let id = try await ImportProjectCoordinator(store: store, session: session)
            .importFolder(from: source.deletingLastPathComponent(), legacyMode: .general)
        XCTAssertEqual(session.activeProject?.id, id)
        XCTAssertEqual(session.activeProject?.mode, .general)
        XCTAssertEqual(session.assetCatalog?.data(for: "images/a.png"), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent("images/a.png")), Data([1, 2, 3]))
    }

    // Import the exact shipped manual-test archive, rather than constructing a
    // different valid archive that could hide a broken owner fixture.
    func testOwnerFixtureImportsAndReopensWithoutChangingSource() async throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/owner-import-general")
        let archive = source.appendingPathComponent("entries.json")
        let original = try Data(contentsOf: archive)
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: url)
        let session = ProjectSession(store: store, defaults: defaults)
        let id = try await ImportProjectCoordinator(store: store, session: session)
            .importFolder(from: source, legacyMode: .general)

        let project = try XCTUnwrap(session.activeProject)
        XCTAssertEqual(project.id, id)
        XCTAssertEqual(project.mode, .general)
        XCTAssertEqual(project.documents.map(\.id.rawValue), [
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!])
        XCTAssertEqual(project.documents.map(\.title), ["문서 A", "문서 B"])
        XCTAssertEqual(project.documents.map(\.body), [
            "# 1장\n\n## 역\n\n### 입구\n\n미나는 푸른 우산을 들었다.\n\n### 승강장\n\n준호도 푸른 우산을 보았다.\n\n# 2장\n\n## 항구\n\n### 부두\n\n상자 안에 푸른 우산이 있었다.\n",
            "# 문서 B\n\n문서 B에도 푸른 우산이 있다.\n\n문서 B에만 있는 표식: 은빛 열쇠.\n"])
        let reopened = ProjectSession(store: ProjectStore(root: url), defaults: defaults)
        try await reopened.bootstrap()
        XCTAssertEqual(reopened.activeProject, project)
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testModernCancellationAndActivationFailureKeepCurrentOwner() async throws {
        for failure in ["cancel", "activate"] {
            let url = root()
            defer { try? FileManager.default.removeItem(at: url) }
            let (source, imported) = try await writeModernFixture(at: url.appendingPathComponent("development"))
            let original = try Data(contentsOf: source.appendingPathComponent("project.json"))
            let (defaults, suite) = defaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let target = url.appendingPathComponent("container")
            let normal = ProjectStore(root: target)
            let current = projectFixture()
            try await normal.save(current)
            try await normal.activate(id: current.id)
            let marker = target.appendingPathComponent("active-project.json")
            let markerBytes = try Data(contentsOf: marker)
            let store = failure == "activate" ? ProjectStore(root: target,
                fileSystem: FailingProjectFiles(fragment: "active-project.json")) : normal
            let session = ProjectSession(store: store, defaults: defaults)
            try await session.bootstrap()
            let identity = session.runtimeIdentity
            let coordinator = ImportProjectCoordinator(store: store, session: session,
                cancellationCheckpoint: { if failure == "cancel" { throw CancellationError() } })
            do { _ = try await coordinator.importProject(from: source); XCTFail("Failed handoff accepted") }
            catch { if failure == "cancel" { XCTAssertTrue(error is CancellationError) } }
            XCTAssertEqual(session.activeProject, current)
            XCTAssertEqual(session.runtimeIdentity, identity)
            XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), original)
            let prepared = try await normal.load(id: imported.id)
            XCTAssertEqual(prepared, imported)
        }
    }

    func testDamagedModernFolderDoesNotFallBackToLegacyEntries() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let (source, _) = try await writeModernFixture(at: url.appendingPathComponent("development"))
        _ = try writeLegacyFixture(at: source)
        try Data("damaged manifest".utf8).write(to: source.appendingPathComponent("project.json"))
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: url.appendingPathComponent("container"))
        let session = ProjectSession(store: store, defaults: defaults)
        do {
            _ = try await ImportProjectCoordinator(store: store, session: session)
                .importFolder(from: source, legacyMode: .general)
            XCTFail("Damaged modern manifest imported as legacy")
        } catch {}
        XCTAssertNil(session.activeProject)
        let active = try await store.activeProject()
        XCTAssertNil(active)
    }

    func testImportPreservesSourceAndPublishesVerifiedProject() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try writeLegacyFixture(at: url)
        let original = try Data(contentsOf: source)
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: url.appendingPathComponent("Projects"))
        let session = ProjectSession(store: store, defaults: defaults)
        let coordinator = ImportProjectCoordinator(store: store, session: session)

        let result = try await coordinator.importLegacy(
            from: source,
            mode: .fiction,
            title: "Imported Novel")

        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(session.activeProject?.id, result.projectID)
        XCTAssertEqual(session.activeProject?.mode, .fiction)
        XCTAssertEqual(session.activeProject?.documents.first?.body,
            "한글\r\n가\n![그림](images/a.png)\n")
        let importedState = try await FirstRunStateResolver.resolve(using: store)
        XCTAssertEqual(importedState, .ready(result.projectID))
    }

    func testFailedImportLeavesCurrentSessionAndSourceUntouched() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let broken = url.appendingPathComponent("broken.json")
        let original = Data("not-json".utf8)
        try original.write(to: broken)

        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: url.appendingPathComponent("Projects"))
        let session = ProjectSession(store: store, defaults: defaults)
        let created = try await ProjectCreationCoordinator(session: session)
            .createProject(title: "Current", mode: .general)

        let coordinator = ImportProjectCoordinator(store: store, session: session)
        do {
            _ = try await coordinator.importLegacy(
                from: broken,
                mode: .fiction,
                title: "Broken")
            XCTFail("Malformed import unexpectedly succeeded")
        } catch {}

        XCTAssertEqual(session.activeProject?.id, created.projectID)
        XCTAssertEqual(try Data(contentsOf: broken), original)
        let activeAfterFailure = try await store.activeProject()
        XCTAssertEqual(activeAfterFailure?.id, created.projectID)
    }

    /// Protected break: using the activating legacy migration before the cancellation
    /// checkpoint would replace the durable owner while the session still shows Current.
    func testCancelledPreparedImportLeavesCurrentSessionAndMarkerUntouched() async throws {
        let url = root()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try writeLegacyFixture(at: url)
        let original = try Data(contentsOf: source)
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: url.appendingPathComponent("Projects"))
        let session = ProjectSession(store: store, defaults: defaults)
        let current = try await ProjectCreationCoordinator(session: session)
            .createProject(title: "Current", mode: .general)
        let coordinator = ImportProjectCoordinator(
            store: store,
            session: session,
            cancellationCheckpoint: { throw CancellationError() })

        do {
            _ = try await coordinator.importLegacy(
                from: source,
                mode: .fiction,
                title: "Import")
            XCTFail("Cancelled import unexpectedly succeeded")
        } catch is CancellationError {
            // Expected at the prepare/commit boundary.
        }

        let durable = try await store.activeProject()
        XCTAssertEqual(session.activeProject?.id, current.projectID)
        XCTAssertEqual(durable?.id, current.projectID)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
