@testable import PurloryStorage
import XCTest
@testable import PurloryCore

@MainActor
final class WriterDataActivationTests: XCTestCase {
    // Catches any owner adoption path bypassing migration for an already-imported project.
    func testAllAdoptionPathsPrepareArchivedWriterDataWithoutModel() async throws {
        for path in ["bootstrap", "activate", "save", "resume"] {
            let f = try await writerMigrationFixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let suite = "purlory.writer-activation.\(UUID())", defaults: UserDefaults
            defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = ProjectSession(store: f.store, defaults: defaults,
                prepareProject: { project, store in try await ProjectWriterDataMigration.prepare(project, store: store) })
            switch path {
            case "bootstrap":
                try await f.store.activate(id: f.project.id)
                try await session.bootstrap()
            case "activate":
                try await session.bootstrap()
                try await session.activateProject(id: f.project.id)
            case "save": try await session.saveAndActivate(f.project)
            default:
                try await session.bootstrap()
                try await session.suspend()
                try await f.store.activate(id: f.project.id)
                try await session.resume()
            }
            let snapshot = try XCTUnwrap(session.selectedDocumentSnapshot)
            let writer = try WriterDocumentData.decode(snapshot.userData[WriterDocumentData.key(for: f.documentID)], documentID: f.documentID)
            XCTAssertEqual(writer.genre, "판타지", path)
            XCTAssertEqual(writer.characters.first?.note, "작가 설정", path)
            XCTAssertEqual(session.phase, .ready)
            let durable = try await f.store.activeProject()
            XCTAssertEqual(durable?.userData[WriterDocumentData.key(for: f.documentID)], snapshot.userData[WriterDocumentData.key(for: f.documentID)])
            XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        }
    }

    // Catches typed corruption changing an active marker or releasing the suspended owner.
    func testBadWriterDataCannotActivateOrReleasePreviousOwner() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let owner = projectFixture()
        var target = projectFixture()
        target.userData[WriterDocumentData.key(for: target.documents[0].id)] = Data("broken".utf8)
        try await store.save(owner); try await store.activate(id: owner.id); try await store.save(target)
        let suite = "purlory.writer-activation.\(UUID())", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: store, defaults: defaults,
            prepareProject: { project, store in try await ProjectWriterDataMigration.prepare(project, store: store) })
        try await session.bootstrap()
        for saveFirst in [false, true] {
            do {
                if saveFirst { try await session.saveAndActivate(target) }
                else { try await session.activateProject(id: target.id) }
                XCTFail("Bad typed data activated")
            } catch {}
            XCTAssertEqual(session.activeProject?.id, owner.id)
            XCTAssertEqual(session.phase, .ready)
            let active = try await store.activeProject()
            XCTAssertEqual(active?.id, owner.id)
        }
        try await session.suspend()
        try await store.activate(id: target.id)
        var released = false
        do { try await session.resume(releasing: { released = true }); XCTFail("Corrupt owner resumed") } catch {}
        XCTAssertFalse(released)
        XCTAssertEqual(session.phase, .suspended)
        XCTAssertNil(session.activeProject)
        let fresh = ProjectSession(store: store, defaults: defaults,
            prepareProject: { project, store in try await ProjectWriterDataMigration.prepare(project, store: store) })
        do { try await fresh.bootstrap(); XCTFail("Corrupt owner bootstrapped") } catch {}
        XCTAssertEqual(fresh.phase, .failed)
        XCTAssertNil(fresh.activeProject)
        let preserved = try await store.load(id: owner.id)
        XCTAssertEqual(preserved, owner)
    }

    // Catches adoption of unpersisted preparation output and cancelled target work.
    func testUncommittedPreparationAndCancellationKeepActiveOwner() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let owner = projectFixture(), target = projectFixture()
        try await store.save(owner); try await store.save(target); try await store.activate(id: owner.id)
        let suite = "purlory.writer-activation.\(UUID())", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for cancel in [false, true] {
            let session = ProjectSession(store: store, defaults: defaults, prepareProject: { project, _ in
                guard project.id == target.id else { return project }
                if cancel { withUnsafeCurrentTask { $0?.cancel() }; try Task.checkCancellation() }
                var uncommitted = project; uncommitted.userData["not-written"] = Data([1])
                return uncommitted
            })
            try await session.bootstrap()
            let task = Task { try await session.activateProject(id: target.id) }
            do { try await task.value; XCTFail("Unverified/cancelled preparation accepted") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } }
            XCTAssertEqual(session.activeProject?.id, owner.id)
            XCTAssertEqual(session.phase, .ready)
            let active = try await store.activeProject()
            XCTAssertEqual(active?.id, owner.id)
            let unchanged = try await store.load(id: target.id)
            XCTAssertNil(unchanged.userData["not-written"])
        }
    }

    // Catches a target changed after preparation being activated without typed verification.
    func testLateTargetChangeCannotCommitActivation() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root), owner = projectFixture(), target = projectFixture()
        try await store.save(owner); try await store.save(target); try await store.activate(id: owner.id)
        let manifest = root.appendingPathComponent("\(target.id.rawValue.uuidString)/project.json")
        let before = try Data(contentsOf: manifest)
        var incoming = target
        incoming.userData[WriterDocumentData.key(for: target.documents[0].id)] = Data("broken".utf8)
        try await store.save(incoming)
        let after = try Data(contentsOf: manifest)
        try before.write(to: manifest)
        let files = WriterActivationArrivalFiles(manifest: manifest, incoming: after)
        let controlled = ProjectStore(root: root, fileSystem: files)
        let suite = "purlory.writer-activation.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: controlled, defaults: defaults, prepareProject: { project, store in
            let prepared = try await ProjectWriterDataMigration.prepare(project, store: store)
            if project.id == target.id { files.arm() }
            return prepared
        })
        try await session.bootstrap()
        do { try await session.activateProject(id: target.id); XCTFail("Changed target activated") } catch {}
        XCTAssertEqual(session.activeProject?.id, owner.id)
        let active = try await store.activeProject()
        XCTAssertEqual(active?.id, owner.id)
        XCTAssertEqual(try Data(contentsOf: manifest), after, "Never overwrite the newer target")
    }
}

private final class WriterActivationArrivalFiles: ProjectFileSystem, @unchecked Sendable {
    let manifest: URL, incoming: Data
    private let real = LocalProjectFileSystem(), lock = NSLock()
    private var reads: Int?
    init(manifest: URL, incoming: Data) { self.manifest = manifest; self.incoming = incoming }
    func arm() { lock.withLock { reads = 0 } }
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws { try real.writeAtomically(data, to: url) }
    func read(_ url: URL) throws -> Data {
        let data = try real.read(url)
        if url == manifest {
            let deliver = lock.withLock {
                guard let count = reads else { return false }
                reads = count + 1
                return count == 1
            }
            if deliver { try real.writeAtomically(incoming, to: manifest) }
        }
        return data
    }
}
