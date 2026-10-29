@_spi(Benchmark) @testable import PurloryInference
@testable import PurloryStorage
import AppKit
import XCTest
@testable import PurloryCore

@MainActor
final class LegacyWorkspaceControllerTests: XCTestCase {
    // Catches releasing the only editable owner before fallible resume verification succeeds.
    func testFailedProjectReloadKeepsLegacyOwnerConsumersAndUndo() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller()
        try await controller.enter()
        let owner = try XCTUnwrap(controller.legacyStore)
        let undo = UndoManager()
        undo.groupsByEvent = false
        owner.structureUndoManager = undo
        let id = owner.activeID
        let folder = owner.newFolder()
        undo.beginUndoGrouping()
        owner.move(id, toFolder: folder)
        undo.endUndoGrouping()
        var consumersDetached = false
        controller.willLeaveLegacy = { consumersDetached = true }
        let marker = fixture.root.appendingPathComponent("Projects/active-project.json")
        let bytes = try Data(contentsOf: marker)
        try Data("invalid active project".utf8).write(to: marker)
        do { try await controller.leave(); XCTFail("Corrupt active marker resumed") } catch {}
        XCTAssertTrue(controller.legacyStore === owner)
        XCTAssertEqual(controller.mode, .legacy)
        XCTAssertFalse(controller.isTransitioning)
        XCTAssertFalse(consumersDetached)
        XCTAssertNil(fixture.session.activeProject)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertNil(owner.entries.first(where: { $0.id == id })?.folderID)
        controller.updateLegacyBody("editable after failed reload")
        XCTAssertEqual(owner.activeEntry?.body, "editable after failed reload")
        try bytes.write(to: marker)
        try await controller.leave()
        XCTAssertEqual(fixture.session.activeProject?.id, fixture.project.id)
        XCTAssertTrue(consumersDetached)
    }

    // Catches initial bootstrap racing legacy entry and publishing a project over its writer.
    func testLegacyEntryRejectsUnresolvedProjectLoading() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let loading = ProjectSession(store: fixture.store, defaults: fixture.defaults)
        var constructed = false
        let controller = LegacyWorkspaceController(session: loading, entryStoreFactory: {
            constructed = true
            return EntryStore(directory: fixture.legacyRoot, autosaveDelay: .seconds(3600))
        })
        do { try await controller.enter(); XCTFail("Unresolved project allowed legacy entry") } catch {}
        XCTAssertFalse(constructed)
        XCTAssertEqual(loading.phase, .loading)
    }

    // Catches a direct public resume call bypassing the legacy controller's release transaction.
    func testDirectResumeCannotCreateAProjectOwnerWhileLegacyIsEditable() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller()
        try await controller.enter()
        do { try await fixture.session.resume(); XCTFail("Resumed while legacy still owns editing") } catch {}
        XCTAssertNil(fixture.session.activeProject)
        XCTAssertEqual(fixture.session.phase, .suspended)
        XCTAssertEqual(controller.mode, .legacy)
        try await controller.leave()
        XCTAssertEqual(fixture.session.phase, .ready)
    }

    // Catches project providers leaking into the explicit legacy editor and lost conversation writes.
    func testLegacyConsumerConnectionsUseOnlyLegacyContextAndDecisions() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller()
        let settings = CompletionSettings(defaults: fixture.defaults)
        let completion = CompletionController(settings: settings)
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        defer { completion.shutdown(); indexer.shutdown() }
        completion.projectDocumentProvider = { fixture.session.selectedDocumentSnapshot }
        controller.didEnterLegacy = {
            LegacyWorkspaceView.connect(store: $0, completion: completion, indexer: indexer)
        }
        try await controller.enter()
        let store = try XCTUnwrap(controller.legacyStore)
        store.updateActiveBody("\"Hello\"\n\"Goodbye\"")
        XCTAssertNil(completion.projectDocumentProvider)
        XCTAssertEqual(completion.documentContextProvider?()?.entryID, store.activeID)
        let record = RecordedConversation(utf16Start: 0, utf16End: 17,
            firstLine: "Hello", lastLine: "Goodbye", contentHash: "conversation-fixture")
        completion.onRecordConversation?(record)
        XCTAssertEqual(store.activeEntry?.recordedConversations, [record])
        XCTAssertEqual(completion.recordedConversationHashesProvider?(), ["conversation-fixture"])
        try await controller.leave()
        let durable = try await fixture.store.activeProject()
        XCTAssertEqual(durable?.documents[0].body, "original project")
    }

    // Catches constructing a second writer before the project flush/barrier has completed.
    func testEnteringLegacyFlushesProjectBeforeConstructingEntryStore() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let session = fixture.session
        session.updateSelectedDocumentBody("durable before legacy")
        var constructions = 0
        session.willTransition = { session.updateSelectedDocumentBody("committed marked text") }
        let controller = LegacyWorkspaceController(session: session, entryStoreFactory: {
            constructions += 1
            XCTAssertNil(session.activeProject)
            XCTAssertNil(session.assetCatalog)
            XCTAssertNil(session.runtimeIdentity)
            XCTAssertEqual(session.phase, .suspended)
            return EntryStore(directory: fixture.legacyRoot, autosaveDelay: .seconds(3600))
        })
        try await controller.enter()
        try await controller.enter()
        let durable = try await fixture.store.activeProject()
        XCTAssertEqual(durable?.documents[0].body, "committed marked text")
        XCTAssertEqual(durable?.id, fixture.project.id)
        XCTAssertEqual(controller.mode, .legacy)
        XCTAssertEqual(constructions, 1)
        XCTAssertNotNil(controller.legacyStore)
        XCTAssertNil(session.selectedDocumentSnapshot)
    }

    // Catches dropping the dirty project, or constructing legacy, after a failed save.
    func testFailedProjectFlushKeepsProjectOwnerAndReconnectsReaders() async throws {
        let fixture = try await LegacyBoundaryFixture(failProjectWrites: true)
        defer { fixture.cleanUp() }
        let session = fixture.session
        session.updateSelectedDocumentBody("unsaved project")
        let identity = session.runtimeIdentity
        var reconnected: ProjectDocumentSnapshot?
        session.documentDidChange = { reconnected = $0 }
        var constructions = 0
        let controller = LegacyWorkspaceController(session: session, entryStoreFactory: {
            constructions += 1
            return EntryStore(directory: fixture.legacyRoot, autosaveDelay: .seconds(3600))
        })
        do { try await controller.enter(); XCTFail("Failed save allowed legacy entry") } catch {}
        XCTAssertEqual(constructions, 0)
        XCTAssertEqual(controller.mode, .project)
        XCTAssertNil(controller.legacyStore)
        XCTAssertEqual(session.selectedDocument?.body, "unsaved project")
        XCTAssertEqual(session.runtimeIdentity, identity)
        XCTAssertEqual(reconnected?.identity, identity)
        XCTAssertEqual(session.savePhase, .failed)
        XCTAssertEqual(session.phase, .ready)
    }

    // Catches project activation bypassing the suspended ownership boundary.
    func testSuspendedSessionRejectsOtherActivationPaths() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller()
        try await controller.enter()
        do { try await fixture.session.activateProject(id: fixture.project.id); XCTFail("Activated while legacy owns editing") } catch {}
        do { try await fixture.session.saveAndActivate(fixture.project); XCTFail("Saved/activated while legacy owns editing") } catch {}
        do { try await fixture.session.bootstrap(); XCTFail("Bootstrapped while legacy owns editing") } catch {}
        XCTAssertNil(fixture.session.activeProject)
        XCTAssertEqual(fixture.session.phase, .suspended)
    }

    // Catches releasing the only dirty legacy value or resuming project after a failed flush.
    func testFailedLegacyFlushRetainsLegacyOwnerForRetry() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller()
        try await controller.enter()
        let legacy = try XCTUnwrap(controller.legacyStore)
        legacy.updateActiveBody("unsaved legacy")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.legacyRoot.path)
        do { try await controller.leave(); XCTFail("Failed legacy save allowed project resume") } catch {}
        XCTAssertTrue(controller.legacyStore === legacy)
        XCTAssertEqual(controller.mode, .legacy)
        XCTAssertEqual(legacy.activeEntry?.body, "unsaved legacy")
        XCTAssertNil(fixture.session.activeProject)
        XCTAssertEqual(fixture.session.phase, .suspended)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.legacyRoot.path)
        try await controller.leave()
        let reloaded = EntryStore(directory: fixture.legacyRoot, autosaveDelay: .seconds(3600))
        XCTAssertEqual(reloaded.activeEntry?.body, "unsaved legacy")
    }

    // Catches legacy retaining ownership when the verified project snapshot is republished.
    func testLeavingReleasesLegacyBeforeRestoringProjectIdentityAndAssets() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let session = fixture.session
        _ = try await session.importAsset(data: Data([7]), reference: "images/a.png", for: XCTUnwrap(session.runtimeIdentity))
        let oldIdentity = session.runtimeIdentity
        let controller = fixture.controller()
        try await controller.enter()
        weak var released = controller.legacyStore
        controller.legacyStore?.updateActiveBody("legacy is durable")
        var published: ProjectDocumentSnapshot?
        session.documentDidChange = { snapshot in
            XCTAssertNil(controller.legacyStore)
            XCTAssertNil(released)
            published = snapshot
        }
        try await controller.leave()
        XCTAssertEqual(controller.mode, .project)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.activeProject?.id, fixture.project.id)
        XCTAssertEqual(published?.body, "original project")
        XCTAssertNotEqual(session.runtimeIdentity, oldIdentity)
        XCTAssertEqual(session.assetCatalog?.data(for: "images/a.png"), Data([7]))
        let durable = try await fixture.store.activeProject()
        XCTAssertEqual(durable?.id, fixture.project.id)
    }
}

@MainActor
struct LegacyBoundaryFixture {
    let root: URL
    let legacyRoot: URL
    let defaults: UserDefaults
    let suite: String
    let store: ProjectStore
    let session: ProjectSession
    let project: WritingProject

    init(failProjectWrites: Bool = false, projectTitle: String = "Project", mode: WritingMode = .general) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-LegacyBoundary-\(UUID())")
        legacyRoot = root.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        suite = "Purlory-LegacyBoundary-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        store = ProjectStore(root: root.appendingPathComponent("Projects"))
        project = WritingProject(id: WritingProjectID(), title: projectTitle, mode: mode, documents: [
            WritingDocument(id: WritingDocumentID(), title: "Manuscript", body: "original project", kind: .manuscript)])
        try await store.save(project)
        try await store.activate(id: project.id)
        let sessionStore = failProjectWrites
            ? ProjectStore(root: root.appendingPathComponent("Projects"), fileSystem: FailingProjectFiles(fragment: "/Documents/"))
            : store
        session = ProjectSession(store: sessionStore, defaults: defaults, autosaveDelay: .seconds(3600))
        try await session.bootstrap()
    }

    func controller() -> LegacyWorkspaceController {
        LegacyWorkspaceController(session: session, entryStoreFactory: {
            EntryStore(directory: legacyRoot, autosaveDelay: .seconds(3600))
        })
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyRoot.path)
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}
