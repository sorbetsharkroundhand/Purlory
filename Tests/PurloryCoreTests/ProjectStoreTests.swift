@testable import PurloryStorage
import XCTest
@testable import PurloryCore

final class ProjectStoreTests: XCTestCase {
    // Catches dropped manuscript/trash/source records and unverified or mutable asset storage.
    func testAddAssetPersistsVerifiedBytesAndRetainsExistingDocuments() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()
        project.trashedDocumentIDs = [project.documents[1].id]
        try await store.save(project)
        try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
        let asset = try await store.assetData(reference: "images/a.png", in: project.id)
        let reopened = try await store.load(id: project.id)
        XCTAssertEqual(asset, Data([1, 2, 3]))
        XCTAssertEqual(reopened, project)
        let catalog = try await store.assetCatalog(id: project.id)
        try await store.addAsset(Data([4, 5]), reference: "images/a.png", to: project.id)
        let replacement = try await store.assetCatalog(id: project.id)
        XCTAssertEqual(catalog.projectID, project.id)
        XCTAssertEqual(catalog.data(for: "images/a.png"), Data([1, 2, 3]))
        XCTAssertEqual(replacement.data(for: "images/a.png"), Data([4, 5]))
        let oldBlob = root.appendingPathComponent("\(project.id.rawValue.uuidString)/Assets/039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
        XCTAssertEqual(try Data(contentsOf: oldBlob), Data([1, 2, 3]))
        let recovered = try await store.previousProject(id: project.id)
        XCTAssertEqual(recovered, project)
    }

    func testAssetWriteFailureAndUnsafePathsPreserveManifest() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = projectFixture()
        try await store.save(project)
        let manifestURL = root.appendingPathComponent("\(project.id.rawValue.uuidString)/project.json")
        let original = try Data(contentsOf: manifestURL)
        for reference in ["../outside", "/tmp/outside", "images/../outside", "images//a.png"] {
            do { try await store.addAsset(Data([1]), reference: reference, to: project.id); XCTFail("Unsafe reference accepted") }
            catch ProjectStoreError.unsafePath {}
        }
        let failing = ProjectStore(root: root, fileSystem: FailingProjectFiles(fragment: "project.json"))
        do { try await failing.addAsset(Data([1]), reference: "images/a.png", to: project.id); XCTFail("Failed commit accepted") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
        let assets = root.appendingPathComponent("\(project.id.rawValue.uuidString)/Assets")
        let outside = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(at: assets, to: assets.appendingPathExtension("saved"))
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: outside)
        do { try await store.addAsset(Data([2]), reference: "images/b.png", to: project.id); XCTFail("Symlink write accepted") }
        catch ProjectStoreError.unsafePath {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
    }

    func testCatalogRejectsDamagedBytesAndDoesNotConsultDiskAfterCreation() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = projectFixture()
        try await store.save(project)
        try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
        let catalog = try await store.assetCatalog(id: project.id)
        let blob = root.appendingPathComponent("\(project.id.rawValue.uuidString)/Assets/039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
        try Data([9]).write(to: blob)
        XCTAssertEqual(catalog.data(for: "images/a.png"), Data([1, 2, 3]))
        XCTAssertNil(catalog.data(for: "../outside"))
        do { _ = try await store.assetCatalog(id: project.id); XCTFail("Damaged asset published") }
        catch ProjectStoreError.damagedFile {}
    }

    func testActivateAndLoadReturnsExactlyTheDurableActiveProject() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = projectFixture()
        try await store.save(project)

        let activated = try await store.activateAndLoad(id: project.id)
        let durable = try await store.activeProject()

        XCTAssertEqual(activated, project)
        XCTAssertEqual(durable, project)
    }

    func testSaveAndLoadPreservesTrashedDocumentIDs() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()
        project.trashedDocumentIDs = [project.documents[1].id]

        try await store.save(project)

        let loaded = try await store.load(id: project.id)
        XCTAssertEqual(loaded, project)
    }

    func testManifestEncodesTrashIDsCanonicallyForStableNoOpSaves() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let uuidStrings = [
            "00000000-0000-0000-0000-000000000008",
            "00000000-0000-0000-0000-000000000003",
            "00000000-0000-0000-0000-000000000006",
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000007",
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000005",
            "00000000-0000-0000-0000-000000000004"
        ]
        let ids = uuidStrings.map { WritingDocumentID(rawValue: UUID(uuidString: $0)!) }
        let project = WritingProject(
            id: WritingProjectID(),
            title: "Stable",
            mode: .general,
            documents: ids.map {
                WritingDocument(id: $0, title: "Draft", body: "body", kind: .manuscript)
            },
            trashedDocumentIDs: Set(ids))

        try await store.save(project)

        let projectFolder = root.appendingPathComponent(project.id.rawValue.uuidString)
        let manifestURL = projectFolder.appendingPathComponent("project.json")
        let firstManifest = try Data(contentsOf: manifestURL)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstManifest) as? [String: Any])
        let encodedTrash = try XCTUnwrap(json["trashedDocumentIDs"] as? [[String: String]])
        XCTAssertEqual(
            encodedTrash.compactMap { $0["rawValue"] },
            uuidStrings.sorted())

        var sameProject = project
        sameProject.trashedDocumentIDs = Set(ids.reversed())
        try await ProjectStore(root: root).save(sameProject)

        XCTAssertEqual(try Data(contentsOf: manifestURL), firstManifest)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectFolder.appendingPathComponent("previous-project.json").path))
    }

    func testManifestMissingTrashFieldLoadsWithEmptyTrash() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = projectFixture()
        try await store.save(project)
        let manifestURL = root.appendingPathComponent(
            "\(project.id.rawValue.uuidString)/project.json")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        json.removeValue(forKey: "trashedDocumentIDs")
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        let loaded = try await store.load(id: project.id)

        XCTAssertEqual(loaded, project)
        XCTAssertEqual(loaded.trashedDocumentIDs, [])
    }

    func testSaveRejectsTrashIDMissingFromDocuments() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()
        project.trashedDocumentIDs = [WritingDocumentID()]

        do {
            try await store.save(project)
            XCTFail("Saved a trash ID that does not belong to the project")
        } catch ProjectStoreError.invalidManifest {
        }
    }

    func testLoadRejectsTrashIDMissingFromManifestDocuments() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = projectFixture()
        try await store.save(project)
        let manifestURL = root.appendingPathComponent(
            "\(project.id.rawValue.uuidString)/project.json")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        json["trashedDocumentIDs"] = [try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WritingDocumentID()))]
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        do {
            _ = try await store.load(id: project.id)
            XCTFail("Loaded a trash ID that does not belong to the manifest")
        } catch ProjectStoreError.invalidManifest {
        }
    }

    func testDerivedIntelligenceUsesStableProjectAndDocumentIDs() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentID = WritingDocumentID()
        let projectA = WritingProject(
            id: WritingProjectID(), title: "Renamable A", mode: .fiction,
            documents: [.init(id: documentID, title: "Same title", body: "A", kind: .manuscript)])
        let projectB = WritingProject(
            id: WritingProjectID(), title: "Renamable B", mode: .fiction,
            documents: [.init(id: documentID, title: "Same title", body: "B", kind: .manuscript)])
        let store = ProjectStore(root: root)
        try await store.save(projectA)
        try await store.save(projectB)

        try await store.writeIntelligence(
            Data("project-a".utf8), projectID: projectA.id, documentID: documentID)
        try await store.writeIntelligence(
            Data("project-b".utf8), projectID: projectB.id, documentID: documentID)

        let dataA = try await store.readIntelligence(projectID: projectA.id, documentID: documentID)
        let dataB = try await store.readIntelligence(projectID: projectB.id, documentID: documentID)
        XCTAssertEqual(dataA, Data("project-a".utf8))
        XCTAssertEqual(dataB, Data("project-b".utf8))
        let relative = "\(projectA.id.rawValue.uuidString)/Intelligence/\(documentID.rawValue.uuidString).knowledge.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path))
        XCTAssertFalse(relative.contains(projectA.title))
        XCTAssertFalse(relative.contains(projectA.documents[0].title))
    }

    func testRoundTripKeepsBodiesOutsideManifestAndSurvivesCacheDeletion() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = projectFixture()
        try await store.save(project)
        let folder = root.appendingPathComponent(project.id.rawValue.uuidString)
        let manifest = try String(contentsOf: folder.appendingPathComponent("project.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("원고 고유 문장"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Intelligence"))
        let reopened = try await ProjectStore(root: root).load(id: project.id)
        XCTAssertEqual(reopened, project)
        for (actual, expected) in zip(reopened.documents, project.documents) {
            XCTAssertEqual(Data(actual.body.utf8), Data(expected.body.utf8))
        }
    }

    func testFailedSaveKeepsEntirePreviousRevisionAndActiveSelection() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = projectFixture()
        let store = ProjectStore(root: root)
        try await store.save(original)
        try await store.activate(id: original.id)
        var edited = original
        edited.documents[0].body = "첫 문서 수정"
        edited.documents[1].body = "둘째 문서 수정"
        for failure in ["Notes/", "project.json"] {
            let failing = ProjectStore(root: root, fileSystem: FailingProjectFiles(fragment: failure))
            do {
                try await failing.save(edited)
                XCTFail("쓰기 실패가 성공으로 보고됨")
            } catch {}
            let actual = try await store.activeProject()
            XCTAssertEqual(actual, original)
        }
    }

    func testRejectsTraversalAndSymlinkWithoutReadingOutsideProject() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = projectFixture()
        let store = ProjectStore(root: root)
        try await store.save(project)
        let folder = root.appendingPathComponent(project.id.rawValue.uuidString)
        let manifestURL = folder.appendingPathComponent("project.json")
        let original = try Data(contentsOf: manifestURL)
        for path in ["../outside.md", "/tmp/outside.md"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var documents = try XCTUnwrap(json["documents"] as? [[String: Any]])
            documents[0]["relativePath"] = path
            json["documents"] = documents
            try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
            do { _ = try await store.load(id: project.id); XCTFail("프로젝트 밖 경로 허용") } catch {}
        }
        try original.write(to: manifestURL)
        let documentsURL = folder.appendingPathComponent("Documents")
        try FileManager.default.removeItem(at: documentsURL)
        try FileManager.default.createSymbolicLink(at: documentsURL, withDestinationURL: root)
        do { try await store.save(project); XCTFail("심볼릭 링크 경유 저장 허용") } catch {}
    }

    func testCorruptCurrentRevisionCanReadPreviousWithoutMutatingEither() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let original = projectFixture()
        try await store.save(original)
        var edited = original
        edited.documents[0].body = "수정본"
        try await store.save(edited)
        let manifest = root.appendingPathComponent("\(original.id.rawValue.uuidString)/project.json")
        let broken = Data("broken".utf8)
        try broken.write(to: manifest)
        do { _ = try await store.load(id: original.id); XCTFail("손상 파일을 정상으로 표시") } catch {}
        let recovered = try await store.previousProject(id: original.id)
        XCTAssertEqual(recovered, original)
        XCTAssertEqual(try Data(contentsOf: manifest), broken)
    }
}

func temporaryProjectRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("purlory-project-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func projectFixture() -> WritingProject {
    WritingProject(id: WritingProjectID(), title: "글 모음", mode: .general, documents: [
        WritingDocument(id: WritingDocumentID(), title: "초안", body: "원고 고유 문장\r\n\u{1100}\u{1161} 👩🏽‍💻\n![그림](images/a.png)\n$E=mc^2$\n", kind: .manuscript),
        WritingDocument(id: WritingDocumentID(), title: "메모", body: " \t\r\n", kind: .note)
    ])
}

struct FailingProjectFiles: ProjectFileSystem {
    let fragment: String
    let real = LocalProjectFileSystem()
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func read(_ url: URL) throws -> Data { try real.read(url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws {
        if fragment.hasSuffix("/") ? url.path.contains(fragment) : url.lastPathComponent == fragment {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try real.writeAtomically(data, to: url)
    }
}
