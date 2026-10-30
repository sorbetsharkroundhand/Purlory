@testable import PurloryIntelligence
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ProjectIncrementalSaveTests: XCTestCase {
    // A warm single-document edit must not read unchanged manuscript bytes.
    func testWarmSingleEditReadsOnlyChangedContentAtEveryProjectSize() async throws {
        for count in [1, 100, 120] {
            let root = try temporaryProjectRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let files = CountingProjectFiles(), store = ProjectStore(root: root, fileSystem: files)
            var project = fixture(count: count)
            try await store.save(project)
            files.reset()
            project.documents[0].body += " revised"
            try await store.save(project)
            let changedID = project.documents[0].id.rawValue.uuidString
            XCTAssertTrue(files.contentReads.allSatisfy { $0.contains(changedID) }, "Unchanged content read at \(count) documents")
            XCTAssertEqual(files.contentWrites.count, 1)
            XCTAssertLessThanOrEqual(files.contentReads.count, 2)
            let reopened = try await ProjectStore(root: root).load(id: project.id)
            XCTAssertEqual(reopened, project)
        }
    }

    func testMetadataAndNoOpSavesDoNotReadOrWriteContent() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CountingProjectFiles(), store = ProjectStore(root: root, fileSystem: files)
        var project = fixture(count: 100)
        try await store.save(project)
        files.reset()
        project.title = "Renamed project"
        project.documents[0].title = "Renamed document"
        project.documents.reverse()
        project.trashedDocumentIDs = [project.documents[0].id]
        try await store.save(project)
        try await store.save(project)
        XCTAssertEqual(files.contentReads, [])
        XCTAssertEqual(files.contentWrites, [])
        let reopened = try await ProjectStore(root: root).load(id: project.id)
        XCTAssertEqual(reopened, project)
    }

    func testWarmEditDoesNotRereadAssetsOrUnchangedWriterData() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CountingProjectFiles(), store = ProjectStore(root: root, fileSystem: files)
        var project = fixture(count: 2)
        project.userData["writer"] = Data("durable decision".utf8)
        try await store.save(project)
        try await store.addAsset(Data(repeating: 7, count: 65_536), reference: "images/a.png", to: project.id)
        try await store.save(project)
        files.reset()
        project.documents[0].body += "!"
        try await store.save(project)
        XCTAssertFalse(files.contentReads.contains { $0.contains("/Assets/") || $0.contains("/UserData/") })
        XCTAssertEqual(files.contentWrites.count, 1)
    }

    func testWarmCacheDetectsCorruptionMissingFilesReplacementAndSymlinks() async throws {
        for change in ["in-place", "replacement", "missing", "symlink"] {
            let root = try temporaryProjectRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ProjectStore(root: root)
            var project = fixture(count: 2)
            try await store.save(project)
            let folder = root.appendingPathComponent(project.id.rawValue.uuidString)
            let manifestURL = folder.appendingPathComponent("project.json")
            let originalManifest = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(ProjectManifest.self, from: originalManifest)
            let target = folder.appendingPathComponent(manifest.documents[1].relativePath)
            let original = try Data(contentsOf: target)
            let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date)
            switch change {
            case "missing": try FileManager.default.removeItem(at: target)
            case "symlink":
                let outside = root.appendingPathComponent("outside.md")
                try original.write(to: outside)
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            default:
                try Data(repeating: 65, count: original.count).write(to: target, options: change == "replacement" ? .atomic : [])
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
            }
            project.documents[0].body += " edit"
            do { try await store.save(project); XCTFail("Warm cache trusted \(change)") } catch {}
            XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
        }
    }

    func testWarmCacheStillVerifiesUnchangedAssetsAndUserData() async throws {
        for damageAsset in [true, false] {
            let root = try temporaryProjectRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ProjectStore(root: root)
            var project = fixture(count: 2)
            project.userData["writer"] = Data("decision".utf8)
            try await store.save(project)
            try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
            try await store.save(project)
            let folder = root.appendingPathComponent(project.id.rawValue.uuidString)
            let bytes = try Data(contentsOf: folder.appendingPathComponent("project.json"))
            let manifest = try JSONDecoder().decode(ProjectManifest.self, from: bytes)
            let record = damageAsset ? try XCTUnwrap(manifest.assets.first?.file) : try XCTUnwrap(manifest.userData["writer"])
            try Data("bad".utf8).write(to: folder.appendingPathComponent(record.relativePath))
            project.documents[0].body += " edit"
            do { try await store.save(project); XCTFail("Unchanged damaged content accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("project.json")), bytes)
        }
    }

    func testByteDistinctUnicodeKindAndWriterDataEditsRoundTrip() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = fixture(count: 2)
        project.documents[0].body = "가\r\n"
        project.userData["removed"] = Data([1])
        try await store.save(project)
        project.documents[0].body = "가\r\n"
        project.documents[1].kind = .note
        project.userData.removeValue(forKey: "removed")
        project.userData["added"] = Data([2])
        try await store.save(project)
        let reopened = try await ProjectStore(root: root).load(id: project.id)
        XCTAssertEqual(Array(reopened.documents[0].body.utf8), Array("가\r\n".utf8))
        XCTAssertEqual(reopened.documents[1].kind, .note)
        XCTAssertEqual(reopened.userData, ["added": Data([2])])
    }

    func testExternalManifestInvalidatesBaselineAndRetainsNewAsset() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CountingProjectFiles(), store = ProjectStore(root: root, fileSystem: files)
        var project = fixture(count: 2)
        try await store.save(project)
        let external = ProjectStore(root: root)
        try await external.addAsset(Data([3, 4]), reference: "images/other.png", to: project.id)
        files.reset()
        project.documents[0].body += " edit"
        try await store.save(project)
        XCTAssertTrue(files.contentReads.contains { $0.contains("/Assets/") })
        let bytes = try await external.assetData(reference: "images/other.png", in: project.id)
        XCTAssertEqual(bytes, Data([3, 4]))
    }

    func testFailedCommitDropsBaselineAndRetryPreservesPreviousRevision() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CountingProjectFiles(), store = ProjectStore(root: root, fileSystem: files)
        let original = fixture(count: 2)
        try await store.save(original)
        var updated = original
        updated.documents[0].body += " changed"
        files.failManifest = true
        do { try await store.save(updated); XCTFail("Failed commit accepted") } catch {}
        let unchanged = try await store.load(id: original.id)
        XCTAssertEqual(unchanged, original)
        files.failManifest = false
        files.reset()
        try await store.save(updated)
        XCTAssertTrue(files.contentReads.contains { $0.contains(original.documents[1].id.rawValue.uuidString) })
        let previous = try await store.previousProject(id: original.id)
        let reopened = try await store.load(id: original.id)
        XCTAssertEqual(previous, original)
        XCTAssertEqual(reopened, updated)
    }

    func testStrictLoadDoesNotTrustWarmSaveVersions() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CountingProjectFiles(), store = ProjectStore(root: root, fileSystem: files)
        let project = fixture(count: 2)
        try await store.save(project)
        files.reset()
        _ = try await store.load(id: project.id)
        XCTAssertEqual(files.contentReads.count, 2)
    }

    private func fixture(count: Int) -> WritingProject {
        WritingProject(id: WritingProjectID(), title: "Synthetic", mode: .general,
            documents: (0..<count).map { index in
                WritingDocument(id: WritingDocumentID(), title: "Chapter \(index)",
                    body: "\(index): " + String(repeating: "합성 원고 paragraph.\n", count: 64), kind: .manuscript)
            })
    }
}

private final class CountingProjectFiles: ProjectFileSystem, @unchecked Sendable {
    private let real = LocalProjectFileSystem()
    private let lock = NSLock()
    private var reads: [String] = []
    private var writes: [String] = []
    private var shouldFailManifest = false
    var failManifest: Bool {
        get { lock.withLock { shouldFailManifest } }
        set { lock.withLock { shouldFailManifest = newValue } }
    }
    var contentReads: [String] { lock.withLock { reads.filter(Self.isContent) } }
    var contentWrites: [String] { lock.withLock { writes.filter(Self.isContent) } }
    func reset() { lock.withLock { reads = []; writes = [] } }
    private static func isContent(_ path: String) -> Bool {
        ["/Documents/", "/Notes/", "/Assets/", "/UserData/"].contains { path.contains($0) }
    }
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func version(of url: URL) throws -> ProjectFileVersion? { try real.version(of: url) }
    func read(_ url: URL) throws -> Data {
        lock.withLock { reads.append(url.path) }
        return try real.read(url)
    }
    func writeAtomically(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == "project.json", failManifest { throw CocoaError(.fileWriteUnknown) }
        lock.withLock { writes.append(url.path) }
        try real.writeAtomically(data, to: url)
    }
}
