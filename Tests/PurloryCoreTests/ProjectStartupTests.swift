import XCTest
@testable import PurloryCore

@MainActor
final class ProjectStartupTests: XCTestCase {
    func testStartupMigratesOnlyWhenNoActiveProjectAndPreservesOriginal() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let bytes = try fixture.writeLegacy(), session = fixture.session()
        try await fixture.startup(session).bootstrap()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.activeProject?.mode, .fiction)
        XCTAssertEqual(session.selectedDocumentID?.rawValue, StartupFixture.activeID)
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
        let id = session.activeProject?.id
        session.updateSelectedDocumentBody("latest migrated writing")
        try await session.flush()
        try await fixture.startup(session).openLegacyLibrary()
        XCTAssertEqual(session.activeProject?.id, id)
        XCTAssertEqual(session.selectedDocument?.body, "latest migrated writing")
        let relaunched = fixture.session()
        try await fixture.startup(relaunched).bootstrap()
        XCTAssertEqual(relaunched.activeProject?.id, id)
        XCTAssertEqual(relaunched.selectedDocument?.body, "latest migrated writing")
    }

    func testExistingActiveProjectWinsOverUnreadableLegacy() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let original = projectFixture()
        try await fixture.store.save(original)
        try await fixture.store.activate(id: original.id)
        try Data("broken legacy".utf8).write(to: fixture.source)
        let session = fixture.session()
        try await fixture.startup(session).bootstrap()
        XCTAssertEqual(session.activeProject, original)
    }

    func testCorruptActiveMarkerNeverFallsBackToLegacy() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let bytes = try fixture.writeLegacy()
        let projects = fixture.root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let marker = projects.appendingPathComponent("active-project.json"), broken = Data("broken".utf8)
        try broken.write(to: marker)
        let session = fixture.session()
        do { try await fixture.startup(session).bootstrap(); XCTFail("Bad marker replaced") } catch {}
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.activeProject)
        XCTAssertEqual(try Data(contentsOf: marker), broken)
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
    }

    func testCorruptLegacyDoesNotSilentlyUseRecoveredArchive() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let bytes = try fixture.writeLegacy()
        let recovered = fixture.root.appendingPathComponent("entries-recovered-example.json")
        try bytes.write(to: recovered)
        let broken = Data("broken".utf8)
        try broken.write(to: fixture.source)
        let session = fixture.session()
        do { try await fixture.startup(session).bootstrap(); XCTFail("Silent legacy recovery") } catch {}
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.source), broken)
        _ = try await ImportProjectCoordinator(store: fixture.store, session: session)
            .importLegacy(from: recovered, mode: .fiction, title: "Recovered library")
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(try Data(contentsOf: recovered), bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), broken)
    }

    func testRecoveredArchiveWithoutPrimaryRequiresExplicitSelection() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let bytes = try fixture.writeLegacy()
        try bytes.write(to: fixture.root.appendingPathComponent("entries-recovered-example.json"))
        try FileManager.default.removeItem(at: fixture.source)
        let session = fixture.session()
        do { try await fixture.startup(session).bootstrap(); XCTFail("Lost recovered manuscripts behind first-run") } catch {}
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.activeProject)
    }

    func testOldJournalBecomesEditableProjectWithoutChangingSource() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let journal = fixture.root.appendingPathComponent("journal.md"), bytes = Data("# 초안\r\n가\n".utf8)
        try bytes.write(to: journal)
        let session = fixture.session()
        try await fixture.startup(session).bootstrap()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.activeProject?.mode, .general)
        XCTAssertEqual(session.selectedDocument.map { Data($0.body.utf8) }, bytes)
        XCTAssertEqual(session.activeProject?.userData["legacy-journal.md"], bytes)
        let id = session.activeProject?.id
        session.updateSelectedDocumentBody("continued")
        try await session.flush()
        try await fixture.startup(session).openLegacyLibrary()
        XCTAssertEqual(session.activeProject?.id, id)
        XCTAssertEqual(session.selectedDocument?.body, "continued")
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testEmptyInstallRemainsModelFreeFirstRun() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let session = fixture.session()
        try await fixture.startup(session).bootstrap()
        XCTAssertEqual(session.phase, .needsProject)
        XCTAssertNil(session.activeProject)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testActivationFailureLeavesLegacyUntouchedAndNoMutableOwner() async throws {
        let fixture = try StartupFixture(files: FailingProjectFiles(fragment: "active-project.json"))
        defer { fixture.cleanUp() }
        let bytes = try fixture.writeLegacy(), session = fixture.session()
        do { try await fixture.startup(session).bootstrap(); XCTFail("Failed activation accepted") } catch {}
        XCTAssertNil(session.activeProject)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
    }

    func testMigrationFencesEditingProjectSwitchAndTerminationUntilVerified() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        try fixture.writeLegacy()
        let preparing = expectation(description: "Writer data preparation entered")
        let gate = AsyncStream<Void>.makeStream()
        let session = ProjectSession(store: fixture.store, defaults: fixture.defaults, prepareProject: { project, store in
            preparing.fulfill()
            for await _ in gate.stream { break }
            return try await ProjectWriterDataMigration.prepare(project, store: store)
        })
        let opening = Task { try await fixture.startup(session).bootstrap() }
        await fulfillment(of: [preparing], timeout: 3)
        XCTAssertEqual(session.phase, .loading)
        XCTAssertTrue(session.isTransitioning)
        XCTAssertNil(session.activeProject)
        XCTAssertNil(session.createDocument())
        do { try await session.saveAndActivate(projectFixture()); XCTFail("Concurrent activation accepted") } catch {}
        do { try await session.flushForTermination(); XCTFail("Migration terminated before adoption") } catch {}
        gate.continuation.yield(()); gate.continuation.finish()
        try await opening.value
        XCTAssertEqual(session.phase, .ready)
        XCTAssertFalse(session.isTransitioning)
    }

    func testReopeningMigratedLibraryKeepsAddedAssetsAndCurrentSelection() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        try fixture.writeLegacy()
        let session = fixture.session()
        try await fixture.startup(session).bootstrap()
        let id = try XCTUnwrap(session.activeProject?.id)
        _ = try await session.importAsset(data: Data([9, 8, 7]), reference: "images/new.png", for: XCTUnwrap(session.runtimeIdentity))
        let selected = try XCTUnwrap(session.activeProject?.documents.last?.id)
        session.selectDocument(selected)
        try await fixture.startup(session).openLegacyLibrary()
        XCTAssertEqual(session.activeProject?.id, id)
        XCTAssertEqual(session.selectedDocumentID, selected)
        XCTAssertEqual(session.assetCatalog?.data(for: "images/new.png"), Data([9, 8, 7]))
    }

    // Migration must preserve the writer's selected document and manual order.
    func testLegacyImportRestoresSelectionOrderAndWriterDataWithoutTouchingSource() async throws {
        let fixture = try StartupFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.writeLegacy()
        let session = fixture.session()
        try await session.bootstrap()
        let result = try await ImportProjectCoordinator(store: fixture.store, session: session)
            .importLegacy(from: fixture.source, mode: .fiction, title: "Legacy Library")
        XCTAssertEqual(session.selectedDocumentID?.rawValue, StartupFixture.activeID)
        XCTAssertEqual(session.activeProject?.documents.map(\.title), ["Second", "First"])
        let data = try XCTUnwrap(session.activeProject?.userData[WriterDocumentData.key(for: .init(rawValue: StartupFixture.activeID))])
        let writer = try WriterDocumentData.decode(data, documentID: .init(rawValue: StartupFixture.activeID))
        XCTAssertEqual(writer.characters.first?.name, "유정")
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
        session.updateSelectedDocumentBody("new project edit")
        try await session.flush()
        let repeated = try await ImportProjectCoordinator(store: fixture.store, session: session)
            .importLegacy(from: fixture.source, mode: .fiction, title: "Legacy Library")
        XCTAssertEqual(repeated.projectID, result.projectID)
        XCTAssertEqual(session.selectedDocument?.body, "new project edit")
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
    }
}

@MainActor
private struct StartupFixture {
    static let activeID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let root: URL
    let store: ProjectStore
    let suite = "Purlory.Startup.\(UUID())"
    let defaults: UserDefaults
    var source: URL { root.appendingPathComponent("entries.json") }
    init(files: any ProjectFileSystem = LocalProjectFileSystem()) throws {
        root = try temporaryProjectRoot()
        store = ProjectStore(root: root.appendingPathComponent("Projects"), fileSystem: files)
        defaults = UserDefaults(suiteName: suite)!
    }
    func startup(_ session: ProjectSession) -> ProjectStartupCoordinator {
        ProjectStartupCoordinator(session: session, store: store, storageLocation: .init(rootDirectory: root))
    }
    func session() -> ProjectSession {
        ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600), prepareProject: {
            try await ProjectWriterDataMigration.prepare($0, store: $1)
        })
    }
    @discardableResult func writeLegacy() throws -> Data {
        let bytes = Data(#"{"entries":[{"id":"00000000-0000-0000-0000-000000000101","title":"First","body":"first\r\n가","createdAt":"2026-09-01T00:00:00Z","sortOrder":1},{"id":"00000000-0000-0000-0000-000000000102","title":"Second","body":"second","kind":"novel","createdAt":"2026-09-02T00:00:00Z","sortOrder":0,"characters":[{"id":"00000000-0000-0000-0000-000000000103","name":"유정","aliases":"","note":"keep","locked":true}]}],"activeID":"00000000-0000-0000-0000-000000000102","folders":[]}"#.utf8)
        try bytes.write(to: source)
        return bytes
    }
    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}
