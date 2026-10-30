@testable import PurloryIntelligence
@testable import PurloryStorage
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ProjectRecoveryFlowTests: XCTestCase {
    func testNativePreviewRemainsBoundedForLargeMultilineWriterMetadata() throws {
        var project = projectFixture()
        project.title = String(repeating: "Long title\n", count: 2_000)
        project.documents[0].title = project.title
        project.documents[0].body = String(repeating: "\n", count: 10_000)
        let preview = ProjectBackupPreview(project: project, assetCount: 1, manifestFingerprint: "UI fixture")
        let alert = ProjectRecoveryPanel.makePreviewAlert(preview)
        XCTAssertLessThan(alert.informativeText.count, 400)
        let scroll = try XCTUnwrap(alert.accessoryView as? NSScrollView)
        XCTAssertLessThanOrEqual(scroll.frame.height, 140)
        XCTAssertFalse(try XCTUnwrap(scroll.documentView as? NSTextView).isEditable)
    }
    func testFailedInitialOpenCanPreviewCancelThenReopenVerifiedRecoveryCopy() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await seed(root)
        let folder = root.appendingPathComponent(original.id.rawValue.uuidString)
        try Data("broken current manifest".utf8).write(to: folder.appendingPathComponent("project.json"))
        let source = try directorySnapshot(folder)
        let session = ProjectSession(store: store, defaults: defaults())
        do { try await session.bootstrap(); XCTFail("Broken current opened") } catch {}
        XCTAssertEqual(session.phase, .failed)
        let flow = ProjectRecoveryFlow(session: session)
        let cancelled = try await flow.run { preview in
            XCTAssertEqual(preview.project, original)
            return false
        }
        XCTAssertFalse(cancelled)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.activeProject)
        XCTAssertEqual(try directorySnapshot(folder), source)
        let opened = try await flow.run { _ in true }
        XCTAssertTrue(opened)
        let recovered = try XCTUnwrap(session.activeProject)
        XCTAssertNotEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.documents, original.documents)
        XCTAssertEqual(recovered.userData, original.userData)
        XCTAssertEqual(recovered.title, original.title + " (복구)")
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.hasLoadedActiveProject)
        XCTAssertTrue(session.isEditorEditable)
        XCTAssertEqual(session.runtimeIdentity?.key.projectID, recovered.id)
        XCTAssertEqual(session.assetCatalog?.data(for: "images/a.png"), Data([1, 2, 3]))
        XCTAssertEqual(try directorySnapshot(folder), source)
        let restarted = ProjectSession(store: store, defaults: defaults())
        try await restarted.bootstrap()
        XCTAssertEqual(restarted.activeProject, recovered)
    }

    func testCancelIsReadOnlyAndCannotDetachFocusedRuntime() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try await seed(root)
        let session = ProjectSession(store: store, defaults: defaults())
        try await session.bootstrap()
        let source = try directorySnapshot(root), identity = session.runtimeIdentity
        var transitions = 0
        session.willTransition = { transitions += 1 }
        let cancelled = try await ProjectRecoveryFlow(session: session).run { _ in false }
        XCTAssertFalse(cancelled)
        XCTAssertEqual(transitions, 0)
        XCTAssertEqual(session.runtimeIdentity, identity)
        XCTAssertEqual(try directorySnapshot(root), source)
    }

    func testInvalidBackupNeverReachesConfirmationOrChangesOwner() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, current) = try await seed(root)
        try Data("invalid previous manifest".utf8).write(to: root.appendingPathComponent("\(original.id.rawValue.uuidString)/previous-project.json"))
        let session = ProjectSession(store: store, defaults: defaults())
        try await session.bootstrap()
        let source = try directorySnapshot(root), identity = session.runtimeIdentity
        var shown = false
        do { _ = try await ProjectRecoveryFlow(session: session).run { _ in shown = true; return true }; XCTFail() } catch {}
        XCTAssertFalse(shown)
        XCTAssertEqual(session.activeProject, current)
        XCTAssertEqual(session.runtimeIdentity, identity)
        XCTAssertEqual(try directorySnapshot(root), source)
    }

    func testActivationFailureRetainsOriginalOwnerAndVerifiedInactiveCopy() async throws {
        for phase in ProjectFaultFiles.Phase.allCases {
            let root = try temporaryProjectRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (store, original, current) = try await seed(root)
            let files = ProjectFaultFiles(phase: phase, target: "active-project.json")
            let session = ProjectSession(store: ProjectStore(root: root, fileSystem: files), defaults: defaults())
            try await session.bootstrap()
            let identity = session.runtimeIdentity, folder = root.appendingPathComponent(original.id.rawValue.uuidString)
            let source = try directorySnapshot(folder)
            do { _ = try await ProjectRecoveryFlow(session: session).run { _ in true }; XCTFail() }
            catch let error as ProjectFaultFiles.Failure { XCTAssertEqual(error, .interrupted) }
            XCTAssertEqual(files.hits.count, 1)
            XCTAssertEqual(session.activeProject, current)
            XCTAssertEqual(session.runtimeIdentity, identity)
            XCTAssertEqual(session.phase, .ready)
            XCTAssertEqual(try directorySnapshot(folder), source)
            let persisted = try await store.activeProject()
            XCTAssertEqual(persisted, current)
            let copies = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .compactMap { UUID(uuidString: $0.lastPathComponent) }.filter { $0 != original.id.rawValue }
            XCTAssertEqual(copies.count, 1)
            let copy = try await store.load(id: WritingProjectID(rawValue: try XCTUnwrap(copies.first)))
            XCTAssertEqual(copy.documents, original.documents)
            XCTAssertEqual(copy.userData, original.userData)
        }
    }

    func testPreparationFailurePreservesSourceAndOriginalRuntime() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, current) = try await seed(root)
        let session = ProjectSession(store: store, defaults: defaults(), prepareProject: { project, _ in
            guard project.id == original.id else { throw CocoaError(.fileReadCorruptFile) }
            return project
        })
        try await session.bootstrap()
        let identity = session.runtimeIdentity, folder = root.appendingPathComponent(original.id.rawValue.uuidString)
        let source = try directorySnapshot(folder)
        do { _ = try await ProjectRecoveryFlow(session: session).run { _ in true }; XCTFail() } catch {}
        XCTAssertEqual(session.activeProject, current)
        XCTAssertEqual(session.runtimeIdentity, identity)
        XCTAssertEqual(try directorySnapshot(folder), source)
        let persisted = try await store.activeProject()
        XCTAssertEqual(persisted, current)
    }

    func testSwitchedProjectCannotApplyAnEarlierBackupPreview() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try await seed(root), other = projectFixture()
        try await store.save(other)
        let session = ProjectSession(store: store, defaults: defaults())
        try await session.bootstrap()
        do {
            _ = try await ProjectRecoveryFlow(session: session).run { _ in
                try await session.activateProject(id: other.id)
                return true
            }
            XCTFail("Earlier owner's preview restored over another project")
        } catch let error as ProjectSessionError { XCTAssertEqual(error, .staleRuntime) }
        XCTAssertEqual(session.activeProject, other)
        let persisted = try await store.activeProject()
        XCTAssertEqual(persisted, other)
    }

    func testFailedDirtyFlushKeepsUnsavedManuscriptAndOriginalBackup() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await seed(root)
        let files = ProjectFaultFiles(phase: .beforeWrite, target: "Documents/")
        let session = ProjectSession(store: ProjectStore(root: root, fileSystem: files), defaults: defaults(), autosaveDelay: .seconds(30))
        try await session.bootstrap()
        session.updateSelectedDocumentBody("Unsaved synthetic manuscript")
        let identity = session.runtimeIdentity, folder = root.appendingPathComponent(original.id.rawValue.uuidString)
        let source = try directorySnapshot(folder)
        do { _ = try await ProjectRecoveryFlow(session: session).run { _ in true }; XCTFail() }
        catch let error as ProjectFaultFiles.Failure { XCTAssertEqual(error, .interrupted) }
        XCTAssertEqual(session.selectedDocument?.body, "Unsaved synthetic manuscript")
        XCTAssertEqual(session.runtimeIdentity, identity)
        XCTAssertEqual(session.savePhase, .failed)
        XCTAssertEqual(try directorySnapshot(folder), source)
    }

    func testSuccessfulDirtyFlushRejectsChangedPreviewAndRetainsNewWriting() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await seed(root)
        let session = ProjectSession(store: store, defaults: defaults(), autosaveDelay: .seconds(30))
        try await session.bootstrap()
        session.updateSelectedDocumentBody("Latest synthetic writing")
        let identity = session.runtimeIdentity
        do { _ = try await ProjectRecoveryFlow(session: session).run { _ in true }; XCTFail("Changed backup silently restored") }
        catch let error as ProjectStoreError {
            guard case .changedDuringSave = error else { return XCTFail("Unexpected: \(error)") }
        }
        XCTAssertEqual(session.activeProject?.id, original.id)
        XCTAssertEqual(session.runtimeIdentity, identity)
        XCTAssertEqual(session.selectedDocument?.body, "Latest synthetic writing")
        let persisted = try await store.activeProject()
        XCTAssertEqual(persisted?.documents[0].body, "Latest synthetic writing")
    }

    private func seed(_ root: URL) async throws -> (ProjectStore, WritingProject, WritingProject) {
        let store = ProjectStore(root: root)
        var original = projectFixture()
        original.userData["decision"] = Data("Original durable decision".utf8)
        try await store.save(original)
        try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: original.id)
        var current = original; current.documents[0].body = "Current synthetic manuscript"
        current.userData["decision"] = Data("Current durable decision".utf8)
        try await store.save(current); try await store.activate(id: current.id)
        return (store, original, current)
    }
    private func defaults() -> UserDefaults {
        let suite = "ProjectRecovery-\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
}
