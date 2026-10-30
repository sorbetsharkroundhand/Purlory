@testable import PurloryIntelligence
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ProjectUserDataSessionTests: XCTestCase {
    // Catches metadata mutations bypassing autosave, reader generations or relaunch state.
    func testAddEditDeleteRelaunchAndReaderGenerationWithoutModel() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "purlory.userdata.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        let project = projectFixture()
        try await session.saveAndActivate(project)
        let before = try XCTUnwrap(session.runtimeIdentity)
        try session.updateUserData(Data("first".utf8), for: "writer", identity: before)
        XCTAssertEqual(session.savePhase, .dirty)
        let after = try XCTUnwrap(session.runtimeIdentity)
        XCTAssertGreaterThan(after.generation, before.generation)
        XCTAssertEqual(session.selectedDocumentSnapshot?.userData["writer"], Data("first".utf8))
        try session.updateUserData(Data("edited".utf8), for: "writer", identity: after)
        try await session.flush()
        let reopened = ProjectSession(store: ProjectStore(root: root), defaults: defaults)
        try await reopened.bootstrap()
        XCTAssertEqual(reopened.activeProject?.userData["writer"], Data("edited".utf8))
        XCTAssertEqual(reopened.selectedDocument?.body, project.documents[0].body)
        try reopened.updateUserData(nil, for: "writer", identity: XCTUnwrap(reopened.runtimeIdentity))
        try await reopened.flush()
        let deleted = try await store.load(id: project.id)
        XCTAssertNil(deleted.userData["writer"])
    }

    // Catches captured callbacks retargeting A's data to B or accepting an old A generation.
    func testStaleMutationCannotCrossProjectsOrReturnToOldGeneration() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "purlory.userdata.\(UUID())", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: defaults)
        let a = projectFixture()
        var b = a; b.id = WritingProjectID(); b.title = "B"
        try await session.saveAndActivate(a)
        let oldA = try XCTUnwrap(session.runtimeIdentity)
        try await session.saveAndActivate(b)
        XCTAssertThrowsError(try session.updateUserData(Data("wrong".utf8), for: "writer", identity: oldA))
        XCTAssertTrue(session.activeProject?.userData.isEmpty == true)
        try await session.activateProject(id: a.id)
        XCTAssertThrowsError(try session.updateUserData(Data("old A".utf8), for: "writer", identity: oldA))
        XCTAssertTrue(session.activeProject?.userData.isEmpty == true)
        XCTAssertEqual(session.savePhase, .saved)
    }

    // Catches a flush clearing a newer metadata generation while its old snapshot is writing.
    func testInFlightFlushDrainsNewerWriterDataGeneration() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = UserDataWriteBarrier(started: expectation(description: "Manifest write entered"))
        defer { barrier.release.signal() }
        let store = ProjectStore(root: root, fileSystem: UserDataBarrierFiles(barrier: barrier))
        let suite = "purlory.userdata.\(UUID())", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        let project = projectFixture()
        try await session.saveAndActivate(project)
        try session.updateUserData(Data("first".utf8), for: "writer", identity: XCTUnwrap(session.runtimeIdentity))
        barrier.arm()
        let flush = Task { try await session.flush() }
        await fulfillment(of: [barrier.started], timeout: 2)
        try session.updateUserData(Data("newest".utf8), for: "writer", identity: XCTUnwrap(session.runtimeIdentity))
        barrier.release.signal()
        try await flush.value
        let loaded = try await store.load(id: project.id)
        XCTAssertEqual(loaded.userData["writer"], Data("newest".utf8))
        XCTAssertEqual(session.savePhase, .saved)
    }

    // Catches losing pending author data or changing owners when the metadata commit fails.
    func testFailedWriterSavePreservesCurrentOwnerAndDirtyDecision() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = ProjectStore(root: root)
        let a = projectFixture(), b = projectFixture()
        try await normal.save(a); try await normal.save(b); try await normal.activate(id: a.id)
        let failing = ProjectStore(root: root, fileSystem: FailingProjectFiles(fragment: "UserData/records/"))
        let suite = "purlory.userdata.\(UUID())", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: failing, defaults: defaults, autosaveDelay: .seconds(3600))
        try await session.bootstrap()
        try session.updateUserData(Data("keep pending".utf8), for: "writer", identity: XCTUnwrap(session.runtimeIdentity))
        do { try await session.activateProject(id: b.id); XCTFail("Failed save changed owners") } catch {}
        XCTAssertEqual(session.activeProject?.id, a.id)
        XCTAssertEqual(session.activeProject?.userData["writer"], Data("keep pending".utf8))
        XCTAssertEqual(session.savePhase, .failed)
        let active = try await normal.activeProject()
        XCTAssertEqual(active?.id, a.id)
    }

    // Catches invalid keys dirtying memory before the checked storage boundary can refuse them.
    func testInvalidKeyAndNoOpDoNotDirtyOrAdvanceTheSession() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "purlory.userdata.\(UUID())", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: ProjectStore(root: root), defaults: defaults)
        try await session.saveAndActivate(projectFixture())
        let before = try XCTUnwrap(session.runtimeIdentity)
        XCTAssertThrowsError(try session.updateUserData(Data([1]), for: "../escape", identity: before))
        try session.updateUserData(nil, for: "absent", identity: before)
        XCTAssertEqual(session.runtimeIdentity, before)
        XCTAssertEqual(session.savePhase, .saved)
    }
}

private final class UserDataWriteBarrier: @unchecked Sendable {
    let started: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    init(started: XCTestExpectation) { self.started = started }
    func arm() { lock.withLock { armed = true } }
    func waitIfArmed() {
        let wait = lock.withLock { let value = armed; armed = false; return value }
        if wait { started.fulfill(); _ = release.wait(timeout: .now() + 5) }
    }
}
private struct UserDataBarrierFiles: ProjectFileSystem {
    let barrier: UserDataWriteBarrier
    private let real = LocalProjectFileSystem()
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func read(_ url: URL) throws -> Data { try real.read(url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == "project.json" { barrier.waitIfArmed() }
        try real.writeAtomically(data, to: url)
    }
}
