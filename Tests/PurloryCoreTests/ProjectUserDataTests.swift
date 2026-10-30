@testable import PurloryIntelligence
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ProjectUserDataTests: XCTestCase {
    // Catches an older schema-1 writer silently discarding the new durable references.
    func testNewRecordsUseProtectedSchemaWhileLegacySchemaOneStillLoads() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = try settingUserData(["writer": Data("protected".utf8)], in: projectFixture())
        try await store.save(project)
        let folder = root.appendingPathComponent(project.id.rawValue.uuidString)
        XCTAssertEqual(try manifestJSON(folder)["schemaVersion"] as? Int, 2)
        let legacy = projectFixture()
        try await store.save(legacy)
        let legacyFolder = root.appendingPathComponent(legacy.id.rawValue.uuidString)
        var json = try manifestJSON(legacyFolder)
        json["schemaVersion"] = 1; json.removeValue(forKey: "userData")
        try JSONSerialization.data(withJSONObject: json).write(to: legacyFolder.appendingPathComponent("project.json"))
        let loaded = try await store.load(id: legacy.id)
        XCTAssertEqual(loaded.documents, legacy.documents)
        XCTAssertTrue(try userDataValues(loaded).isEmpty)
        let importedStore = ProjectStore(root: root.appendingPathComponent("restored"))
        let importedID = try await importedStore.prepareProjectImport(from: legacyFolder)
        let imported = try await importedStore.load(id: importedID)
        XCTAssertEqual(imported.documents, legacy.documents)
        try await store.save(loaded)
        XCTAssertEqual(try manifestJSON(legacyFolder)["schemaVersion"] as? Int, 2)
    }

    // Catches omitted opaque fields and accidental cache ownership of writer decisions.
    func testOpaqueDecisionsAreVerifiedOutsideManuscriptAndSurviveIntelligenceReset() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = try settingUserData(["writer-record": Data("owner decision".utf8)], in: projectFixture())
        try await store.save(project)
        let folder = root.appendingPathComponent(project.id.rawValue.uuidString)
        let manifest = try manifestJSON(folder)
        let records = manifest["userData"] as? [String: [String: String]]
        XCTAssertNotNil(records?["writer-record"])
        if let path = records?["writer-record"]?["relativePath"] {
            XCTAssertTrue(path.hasPrefix("UserData/records/"))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), Data("owner decision".utf8))
        }
        XCTAssertFalse(String(data: try Data(contentsOf: folder.appendingPathComponent("project.json")), encoding: .utf8)!.contains("owner decision"))
        try await store.writeIntelligence(Data("old schema".utf8), projectID: project.id, documentID: project.documents[0].id)
        try await store.removeIntelligence(projectID: project.id, documentID: project.documents[0].id)
        let reopened = try await ProjectStore(root: root).load(id: project.id)
        XCTAssertEqual(try userDataValues(reopened)["writer-record"], Data("owner decision".utf8))
        XCTAssertEqual(reopened.documents, project.documents)
    }

    // Catches destructive blob replacement/deletion and dropped unknown future keys.
    func testEditDeleteAndPreviousManifestRecoveryRetainEachDecisionGeneration() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let first = try settingUserData(["writer": Data("first".utf8), "future": Data([0, 1, 255])], in: projectFixture())
        try await store.save(first)
        let second = try settingUserData(["writer": Data("edited".utf8), "future": Data([0, 1, 255])], in: first)
        try await store.save(second)
        let previous = try await store.previousProject(id: first.id)
        XCTAssertEqual(try userDataValues(previous)["writer"], Data("first".utf8))
        let deleted = try settingUserData(["future": Data([0, 1, 255])], in: second)
        try await store.save(deleted)
        let recovered = try await store.previousProject(id: first.id)
        XCTAssertEqual(try userDataValues(recovered)["writer"], Data("edited".utf8))
        let loaded = try await ProjectStore(root: root).load(id: first.id)
        XCTAssertNil(try userDataValues(loaded)["writer"])
        XCTAssertEqual(try userDataValues(loaded)["future"], Data([0, 1, 255]))
    }

    // Catches global/document-only storage that aliases two projects with the same UUID.
    func testSameDocumentAndRecordKeyRemainIsolatedBetweenProjects() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let a = try settingUserData(["writer": Data("A decision".utf8)], in: projectFixture())
        var b = try settingUserData(["writer": Data("B decision".utf8)], in: a)
        b.id = WritingProjectID()
        try await store.save(a); try await store.save(b)
        let reopenedA = try await store.load(id: a.id), reopenedB = try await store.load(id: b.id)
        XCTAssertEqual(try userDataValues(reopenedA)["writer"], Data("A decision".utf8))
        XCTAssertEqual(try userDataValues(reopenedB)["writer"], Data("B decision".utf8))
    }

    // Catches publishing metadata before its bytes or losing the last valid commit on failure.
    func testBlobAndManifestFailuresPreservePriorDecisionAndActiveProject() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let original = try settingUserData(["writer": Data("safe".utf8)], in: projectFixture())
        try await store.save(original); try await store.activate(id: original.id)
        let folder = root.appendingPathComponent(original.id.rawValue.uuidString)
        let originalManifest = try Data(contentsOf: folder.appendingPathComponent("project.json"))
        var changed = try settingUserData(["writer": Data("new".utf8)], in: original)
        changed.documents[0].body = "new manuscript"
        for fragment in ["UserData/records/", "project.json"] {
            let failing = ProjectStore(root: root, fileSystem: FailingProjectFiles(fragment: fragment))
            do { try await failing.save(changed); XCTFail("Failed commit reported success: \(fragment)") } catch {}
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("project.json")), originalManifest)
            let active = try await store.activeProject()
            XCTAssertEqual(try userDataValues(XCTUnwrap(active))["writer"], Data("safe".utf8))
        }
    }

    // Catches unverified UserData and activation of a damaged candidate over a valid owner.
    func testCorruptUserBlobCannotReplaceValidActiveProject() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let original = projectFixture()
        try await store.save(original); try await store.activate(id: original.id)
        let target = try settingUserData(["writer": Data("target".utf8)], in: projectFixture())
        try await store.save(target)
        let folder = root.appendingPathComponent(target.id.rawValue.uuidString)
        let record = (try manifestJSON(folder)["userData"] as? [String: [String: String]])?["writer"]
        guard let path = record?["relativePath"] else { XCTFail("Writer blob not committed"); return }
        try Data("damaged".utf8).write(to: folder.appendingPathComponent(path))
        do { _ = try await store.activateAndLoad(id: target.id); XCTFail("Damaged candidate activated") } catch ProjectStoreError.damagedFile {}
        let active = try await store.activeProject()
        XCTAssertEqual(active, original)
    }

    // Catches arbitrary manifest paths and symlinks bypassing the UserData boundary.
    func testUnsafeRecordManifestAndSymlinkCannotEscapeUserData() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = try settingUserData(["writer": Data("safe".utf8)], in: projectFixture())
        try await store.save(project)
        let folder = root.appendingPathComponent(project.id.rawValue.uuidString)
        let manifestURL = folder.appendingPathComponent("project.json")
        let original = try Data(contentsOf: manifestURL)
        var json = try manifestJSON(folder)
        json["userData"] = ["writer": ["relativePath": "../outside", "contentHash": String(repeating: "0", count: 64)]]
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        do { _ = try await store.load(id: project.id); XCTFail("Arbitrary record path accepted") } catch {}
        try original.write(to: manifestURL)
        let outside = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let records = folder.appendingPathComponent("UserData/records")
        if FileManager.default.fileExists(atPath: records.path) {
            try FileManager.default.moveItem(at: records, to: records.appendingPathExtension("saved"))
        }
        try FileManager.default.createSymbolicLink(at: records, withDestinationURL: outside)
        do { _ = try await store.load(id: project.id); XCTFail("Symlink record path read") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
    }

    // Catches using opaque keys as paths or silently accepting malformed identifiers.
    func testInvalidKeysRefuseSaveAndOldFieldsRemainCompatible() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = projectFixture()
        try await store.save(project)
        for key in ["", "../escape", ".", "..", "a/b", "a\\b", String(repeating: "a", count: 129)] {
            let changed = try settingUserData([key: Data("unsafe".utf8)], in: project)
            do { try await store.save(changed); XCTFail("Invalid record key accepted: \(key)") } catch {}
        }
        let folder = root.appendingPathComponent(project.id.rawValue.uuidString)
        var json = try manifestJSON(folder); json.removeValue(forKey: "userData")
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("project.json"))
        let loaded = try await store.load(id: project.id)
        XCTAssertTrue(try userDataValues(loaded).isEmpty)
        XCTAssertEqual(loaded.documents, project.documents)
    }
}

private func settingUserData(_ values: [String: Data], in project: WritingProject) throws -> WritingProject {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    json["userData"] = values.mapValues { $0.base64EncodedString() }
    return try JSONDecoder().decode(WritingProject.self, from: JSONSerialization.data(withJSONObject: json))
}
private func userDataValues(_ project: WritingProject) throws -> [String: Data] {
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    return (json["userData"] as? [String: String] ?? [:]).compactMapValues { Data(base64Encoded: $0) }
}
private func manifestJSON(_ folder: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("project.json"))) as? [String: Any])
}
