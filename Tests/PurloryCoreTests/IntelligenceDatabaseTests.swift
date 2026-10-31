import Foundation
import SQLite3
import XCTest
@testable import PurloryCore
@testable import PurloryStorage
@testable import PurloryIntelligence

final class IntelligenceDatabaseTests: XCTestCase {
    func testCancelledWriteAndUnsafeFileLeasePreservePriorState() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        var original = KnowledgeSidecar(scope: fixture.scope); original.events["old"] = []
        try await fixture.repository.save(original, scope: fixture.scope)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.repository.save(KnowledgeSidecar(scope: fixture.scope), scope: fixture.scope)
        }
        do { try await task.value; XCTFail("Cancelled save committed") } catch { XCTAssertTrue(error is CancellationError) }
        let loaded = await fixture.repository.load(scope: fixture.scope)
        XCTAssertEqual(loaded, original)
        for name in ["../project.json", ".", "nested/file", "escape\\file"] {
            do {
                _ = try await fixture.store.withIntelligenceFile(projectID: fixture.project.id, name: name) { _ in true }
                XCTFail("Unsafe file lease accepted: \(name)")
            } catch let error as ProjectStoreError {
                guard case .unsafePath = error else { return XCTFail("Unexpected path failure") }
            }
        }
    }

    func testOnlyChangedSceneRowsAreWrittenAndPruningKeepsEmptyCompletedOutputs() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        var sidecar = KnowledgeSidecar(scope: fixture.scope)
        sidecar.events = ["a": [], "b": []]
        try await fixture.repository.save(sidecar, scope: fixture.scope)
        try sql(fixture.database, "CREATE TABLE audit(kind TEXT); CREATE TRIGGER scene_update AFTER UPDATE ON scene_records BEGIN INSERT INTO audit VALUES('update'); END; CREATE TRIGGER scene_delete AFTER DELETE ON scene_records BEGIN INSERT INTO audit VALUES('delete'); END;")
        try await fixture.repository.save(sidecar, scope: fixture.scope)
        XCTAssertEqual(try scalar(fixture.database, "SELECT count(*) FROM audit"), 0)
        sidecar.sceneSummaries["a"] = .init(contentHash: "a", headingPath: [], summary: "Changed", updatedAt: Date(timeIntervalSince1970: 1))
        try await fixture.repository.save(sidecar, scope: fixture.scope)
        XCTAssertEqual(try scalar(fixture.database, "SELECT count(*) FROM audit WHERE kind='update'"), 1)
        try await fixture.repository.save(sidecar, pruningTo: ["a"], scope: fixture.scope)
        XCTAssertEqual(try scalar(fixture.database, "SELECT count(*) FROM audit WHERE kind='delete'"), 1)
        let loaded = await fixture.repository.load(scope: fixture.scope)
        XCTAssertEqual(loaded.events["a"], [])
        XCTAssertNil(loaded.events["b"])
        XCTAssertEqual(loaded.sceneSummaries["a"], sidecar.sceneSummaries["a"])
    }

    func testFailedSceneWriteRollsBackMetadataAndOtherScenes() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        var original = KnowledgeSidecar(scope: fixture.scope)
        original.events = ["a": [], "b": []]
        try await fixture.repository.save(original, scope: fixture.scope)
        try sql(fixture.database, "CREATE TRIGGER reject_scene BEFORE UPDATE ON scene_records WHEN NEW.hash='b' BEGIN SELECT RAISE(FAIL,'injected write failure'); END;")
        var changed = original; changed.generation = 9
        for hash in ["a", "b"] { changed.sceneSummaries[hash] = .init(contentHash: hash, headingPath: [], summary: "New", updatedAt: .now) }
        do { try await fixture.repository.save(changed, scope: fixture.scope); XCTFail("Faulted save succeeded") } catch {}
        let loaded = await fixture.repository.load(scope: fixture.scope)
        XCTAssertEqual(loaded, original)
    }

    func testDatabaseAndCompanionSymlinksCannotEscapeDerivedStorage() async throws {
        for name in ["knowledge.sqlite3", "knowledge.sqlite3-wal", "knowledge.sqlite3-shm", "knowledge.sqlite3-journal"] {
            let fixture = try await fixture()
            defer { fixture.clean() }
            let victim = fixture.root.appendingPathComponent("writer-owned.data")
            try Data("Do not touch".utf8).write(to: victim)
            let link = fixture.database.deletingLastPathComponent().appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
            do {
                try await fixture.repository.save(KnowledgeSidecar(scope: fixture.scope), scope: fixture.scope)
                XCTFail("A symlink was accepted: \(name)")
            } catch let error as ProjectStoreError {
                guard case .unsafePath = error else { return XCTFail("Unexpected path error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: victim), Data("Do not touch".utf8))
        }
    }

    func testCorruptDerivedDatabaseRebuildAndExplicitRemovalLeaveWriterDataIntact() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        var old = KnowledgeSidecar(scope: fixture.scope); old.generation = 7
        try await fixture.store.writeIntelligence(old.encoded(), projectID: fixture.project.id, documentID: fixture.document.id)
        _ = await fixture.repository.load(scope: fixture.scope)
        try Data("broken derived database".utf8).write(to: fixture.database, options: .atomic)
        let recovered = await fixture.repository.load(scope: fixture.scope)
        XCTAssertEqual(recovered, old)
        try await fixture.repository.remove(scope: fixture.scope)
        let empty = await fixture.repository.load(scope: fixture.scope)
        XCTAssertEqual(empty, KnowledgeSidecar(scope: fixture.scope))
        let preserved = try await fixture.store.load(id: fixture.project.id)
        XCTAssertEqual(preserved, fixture.project)
    }

    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let project: WritingProject
        let document: WritingDocument
        let repository: KnowledgeSidecarRepository
        var scope: StoryMemoryScope { .project(projectID: project.id, documentID: document.id) }
        var database: URL { root.appendingPathComponent("\(project.id.rawValue.uuidString)/Intelligence/knowledge.sqlite3") }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    private func fixture() async throws -> Fixture {
        let root = try temporaryProjectRoot(), store = ProjectStore(root: root)
        let document = WritingDocument(id: WritingDocumentID(), title: "Draft", body: "Writer original", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Project", mode: .fiction, documents: [document], userData: ["writer.data": Data("Durable".utf8)])
        try await store.save(project)
        return Fixture(root: root, store: store, project: project, document: document, repository: KnowledgeSidecarRepository(projectStore: store))
    }
    private func sql(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: Int(result), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))]) }
    }
    private func scalar(_ url: URL, _ sql: String) throws -> Int {
        var handle: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    func testLegacyJSONIsVerifiedIntoSQLiteWithoutChangingItsOriginal() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let document = WritingDocument(id: WritingDocumentID(), title: "Draft", body: "Original", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Project", mode: .fiction, documents: [document])
        try await store.save(project)
        let scope = StoryMemoryScope.project(projectID: project.id, documentID: document.id)
        var old = KnowledgeSidecar(scope: scope)
        old.generation = 4
        old.sceneSummaries["scene"] = .init(contentHash: "scene", headingPath: ["One"], summary: "An event", updatedAt: Date(timeIntervalSince1970: 100))
        let original = try old.encoded()
        try await store.writeIntelligence(original, projectID: project.id, documentID: document.id)
        let repository = KnowledgeSidecarRepository(projectStore: store)
        let loaded = await repository.load(scope: scope)
        XCTAssertEqual(loaded, old)
        let database = root.appendingPathComponent("\(project.id.rawValue.uuidString)/Intelligence/knowledge.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path), "Migration must establish SQLite storage")
        if FileManager.default.fileExists(atPath: database.path) {
            XCTAssertEqual(try Data(contentsOf: database).prefix(16), Data("SQLite format 3\0".utf8))
        }
        let preserved = try await store.readIntelligence(projectID: project.id, documentID: document.id)
        XCTAssertEqual(preserved, original)
        let durable = try await store.load(id: project.id)
        XCTAssertEqual(durable, project)
    }
}
