@testable import PurloryStorage
import XCTest
@testable import PurloryCore

final class ProjectBackupRestoreTests: XCTestCase {
    func testVerifiedCopyPreservesSourceAndAllDurableRecordsIncludingAssets() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var original = projectFixture()
        original.userData["decision"] = Data("Opaque explicit decision".utf8)
        original.trashedDocumentIDs.insert(original.documents[1].id)
        try await store.save(original)
        try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: original.id)
        var current = original; current.documents[0].body = "Changed current manuscript"
        try await store.save(current); try await store.activate(id: original.id)
        try await store.writeIntelligence(Data("broken rebuildable cache".utf8), projectID: original.id,
            documentID: original.documents[0].id)
        let folder = root.appendingPathComponent(original.id.rawValue.uuidString)
        let broken = Data("broken current manifest".utf8)
        try broken.write(to: folder.appendingPathComponent("project.json"))
        let source = try directorySnapshot(folder)
        let preview = try await store.previousBackup(id: original.id)
        XCTAssertEqual(preview.project, original)
        XCTAssertEqual(preview.assetCount, 1)
        let recovered = try await store.prepareBackupRestore(preview)
        XCTAssertNotEqual(recovered.id, original.id)
        var expected = original; expected.id = recovered.id
        XCTAssertEqual(recovered, expected)
        let copiedAsset = try await store.assetData(reference: "images/a.png", in: recovered.id)
        XCTAssertEqual(copiedAsset, Data([1, 2, 3]))
        let copiedCache = try await store.readIntelligence(projectID: recovered.id, documentID: recovered.documents[0].id)
        XCTAssertNil(copiedCache)
        XCTAssertEqual(try directorySnapshot(folder), source)
        let activeID = try await store.activeProjectID()
        XCTAssertEqual(activeID, original.id, "Storage preparation must never activate")
    }

    func testStalePreviewAndCorruptBackupCannotWriteARecoveryCopy() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root), original = projectFixture()
        try await store.save(original)
        var current = original; current.documents[0].body = "Second"
        try await store.save(current)
        let preview = try await store.previousBackup(id: original.id)
        current.documents[0].body = "Third"
        try await store.save(current)
        let before = try directorySnapshot(root)
        do { _ = try await store.prepareBackupRestore(preview); XCTFail("Stale backup copied") }
        catch let error as ProjectStoreError {
            guard case .changedDuringSave = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try directorySnapshot(root), before)
        let folder = root.appendingPathComponent(original.id.rawValue.uuidString)
        let previousURL = folder.appendingPathComponent("previous-project.json")
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: previousURL))
        try Data("broken manuscript".utf8).write(to: folder.appendingPathComponent(manifest.documents[0].relativePath))
        let corrupt = try directorySnapshot(root)
        do { _ = try await store.previousBackup(id: original.id); XCTFail("Unverified backup previewed") } catch {}
        XCTAssertEqual(try directorySnapshot(root), corrupt)
    }

    func testInterruptedRecoveryCopyLeavesOriginalAndItsBackupUntouched() async throws {
        for phase in ProjectFaultFiles.Phase.allCases {
            let root = try temporaryProjectRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ProjectStore(root: root), original = projectFixture()
            try await store.save(original); try await store.activate(id: original.id)
            var current = original; current.documents[0].body = "Current"
            try await store.save(current)
            let folder = root.appendingPathComponent(original.id.rawValue.uuidString)
            let source = try directorySnapshot(folder), marker = try Data(contentsOf: root.appendingPathComponent("active-project.json"))
            let preview = try await store.previousBackup(id: original.id)
            let files = ProjectFaultFiles(phase: phase, target: "project.json")
            let failing = ProjectStore(root: root, fileSystem: files)
            do { _ = try await failing.prepareBackupRestore(preview); XCTFail("Interrupted copy succeeded") }
            catch let error as ProjectFaultFiles.Failure { XCTAssertEqual(error, .interrupted) }
            XCTAssertEqual(files.hits.count, 1)
            XCTAssertEqual(try directorySnapshot(folder), source)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("active-project.json")), marker)
            let active = try await store.activeProject()
            XCTAssertEqual(active, current)
        }
    }

    func testCopiedLegacyArchiveAndAssetsRemainByteExact() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("entries.json")
        let archive = Data(#"{"entries":[{"id":"00000000-0000-0000-0000-000000000101","title":"초안","createdAt":"2026-09-01T00:00:00Z","body":"합성 원고","kind":"novel"}]}"#.utf8)
        try archive.write(to: source)
        let store = ProjectStore(root: root.appendingPathComponent("Projects"))
        let migration = try await store.migrateLegacy(from: source, mode: .general, title: "Synthetic")
        var project = try await store.load(id: migration.projectID)
        project.documents[0].body = "Later edit"; try await store.save(project)
        let preview = try await store.previousBackup(id: project.id)
        let recovered = try await store.prepareBackupRestore(preview)
        let retained = try await store.legacySource(id: recovered.id)
        XCTAssertEqual(retained, archive)
        XCTAssertEqual(try Data(contentsOf: source), archive)
        XCTAssertEqual(recovered.documents[0].body, "합성 원고")
    }
}

/// Byte snapshot excluding only the store's advisory lock; used on fresh fixture roots.
func directorySnapshot(_ root: URL) throws -> [String: Data] {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
    var result: [String: Data] = [:]
    for case let file as URL in enumerator {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
            file.lastPathComponent != ".store.lock" {
            result[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
        }
    }
    return result
}
