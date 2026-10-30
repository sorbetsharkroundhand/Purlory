@testable import PurloryIntelligence
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class LegacyProjectMigrationTests: XCTestCase {
    func testPreparedMigrationDoesNotReplaceActiveProject() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeLegacyFixture(at: root)
        let store = ProjectStore(root: root.appendingPathComponent("Projects"))
        let original = projectFixture()
        try await store.save(original)
        try await store.activate(id: original.id)

        let prepared = try await store.prepareLegacyMigration(
            from: source, mode: .fiction, title: "Imported")
        let active = try await store.activeProject()

        XCTAssertNotEqual(prepared.projectID, original.id)
        XCTAssertEqual(active, original)
    }

    func testFileMigrationPreservesSourceMetadataAssetsAndEditedProjectOnRetry() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeLegacyFixture(at: root)
        let before = try Data(contentsOf: source)
        let store = ProjectStore(root: root.appendingPathComponent("Projects"))
        let result = try await store.migrateLegacy(from: source, mode: .fiction, title: "이관 작품")
        let active = try await store.activeProject()
        var project = try XCTUnwrap(active)
        XCTAssertEqual(project.id, result.projectID)
        XCTAssertEqual(Data(project.documents[0].body.utf8), Data("한글\r\n\u{1100}\u{1161}\n![그림](images/a.png)\n".utf8))
        let archive = try await store.legacySource(id: result.projectID)
        XCTAssertEqual(archive, before)
        let asset = try await store.assetData(reference: "images/a.png", in: result.projectID)
        XCTAssertEqual(asset, Data([1, 2, 3]))
        project.documents[0].body = "이관 후 사용자 편집"
        try await store.save(project)
        let repeated = try await store.migrateLegacy(from: source, mode: .fiction, title: "이관 작품")
        XCTAssertEqual(repeated.projectID, result.projectID)
        XCTAssertTrue(repeated.reusedExistingProject)
        let afterRetry = try await store.activeProject()
        XCTAssertEqual(afterRetry, project)
        let keptArchive = try await store.legacySource(id: result.projectID)
        let keptAsset = try await store.assetData(reference: "images/a.png", in: result.projectID)
        XCTAssertEqual(keptArchive, before)
        XCTAssertEqual(keptAsset, Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testMigrationFailureNeverSwitchesActiveOrChangesLegacy() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeLegacyFixture(at: root)
        let bytes = try Data(contentsOf: source)
        let projects = root.appendingPathComponent("Projects")
        let store = ProjectStore(root: projects)
        let original = projectFixture()
        try await store.save(original)
        try await store.activate(id: original.id)
        for failure in ["Documents/", "Assets/", "active-project.json"] {
            let failing = ProjectStore(root: projects, fileSystem: FailingProjectFiles(fragment: failure))
            do {
                _ = try await failing.migrateLegacy(from: source, mode: .fiction, title: failure)
                XCTFail("미완료 이관이 성공으로 보고됨")
            } catch {}
            let active = try await store.activeProject()
            XCTAssertEqual(active, original)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testCorruptMigrationTargetCreatesSeparateVerifiedProject() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeLegacyFixture(at: root)
        let projects = root.appendingPathComponent("Projects")
        let store = ProjectStore(root: projects)
        var current = try await store.migrateLegacy(from: source, mode: .general, title: "복구")
        for damageAsset in [true, false] {
            let folder = projects.appendingPathComponent(current.projectID.rawValue.uuidString)
            let manifestURL = folder.appendingPathComponent("project.json")
            let manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
            let target = damageAsset ? folder.appendingPathComponent(try XCTUnwrap(manifest.assets.first).file.relativePath) : manifestURL
            let broken = Data("broken".utf8)
            try broken.write(to: target)
            let recovered = try await store.migrateLegacy(from: source, mode: .general, title: "복구")
            XCTAssertNotEqual(recovered.projectID, current.projectID)
            XCTAssertEqual(try Data(contentsOf: target), broken)
            let active = try await store.activeProject()
            XCTAssertEqual(active?.id, recovered.projectID)
            current = recovered
        }
    }

    func testMalformedSourceAndSymlinkAssetFailWithoutActivation() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("entries.json")
        try Data("broken".utf8).write(to: source)
        let store = ProjectStore(root: root.appendingPathComponent("Projects"))
        do { _ = try await store.migrateLegacy(from: source, mode: .general, title: "실패"); XCTFail() } catch {}
        _ = try writeLegacyFixture(at: root)
        let asset = root.appendingPathComponent("images/a.png")
        try FileManager.default.removeItem(at: asset)
        try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: source)
        do { _ = try await store.migrateLegacy(from: source, mode: .general, title: "실패"); XCTFail() } catch {}
        let active = try await store.activeProject()
        XCTAssertNil(active)
    }
}

private func writeLegacyFixture(at root: URL) throws -> URL {
    let data = Data(#"{"entries":[{"id":"00000000-0000-0000-0000-000000000101","title":"초안","createdAt":"2026-09-01T00:00:00Z","body":"한글\r\n가\n![그림](images/a.png)\n","kind":"novel","characters":[{"id":"00000000-0000-0000-0000-000000000102","name":"유정","aliases":"","note":"사용자 설정","locked":true}],"futureUserMetadata":{"keep":true}}],"activeID":"00000000-0000-0000-0000-000000000101","folders":[],"expandedFolderIDs":[]}"#.utf8)
    let source = root.appendingPathComponent("entries.json")
    try data.write(to: source)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: root.appendingPathComponent("images/a.png"))
    return source
}
