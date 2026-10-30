@testable import PurloryIntelligence
@testable import PurloryStorage
import Darwin
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ProjectFolderImportTests: XCTestCase {
    func testPreservesProjectTreeAndReopensWithoutSource() async throws {
        for mode in [WritingMode.general, .fiction] {
            let f = try await fixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let original = try tree(f.source)
            let marker = try Data(contentsOf: f.marker)
            let id = try await f.store.prepareProjectImport(from: f.source)
            XCTAssertEqual(id, f.project.id)
            XCTAssertEqual(try tree(f.imported), original)
            XCTAssertEqual(try tree(f.source), original)
            XCTAssertEqual(try Data(contentsOf: f.marker), marker)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.deletingLastPathComponent()
                .appendingPathComponent(".store.lock").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.imported.appendingPathComponent("UserData/empty").path))
            try await f.store.activate(id: id)
            try FileManager.default.removeItem(at: f.source)
            let reopened = ProjectStore(root: f.target)
            let project = try await reopened.activeProject()
            let previous = try await reopened.previousProject(id: id)
            let image = try await reopened.assetData(reference: "images/a.png", in: id)
            XCTAssertEqual(project, f.project)
            XCTAssertEqual(previous, f.previous)
            XCTAssertEqual(image, Data([1, 2, 3]))
        }
    }

    func testRejectsCollisionWithoutChangingEitherProject() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var existing = f.project
        existing.documents[0].body = "Destination writer's version"
        try await f.store.save(existing)
        let destination = try tree(f.imported)
        let source = try tree(f.source)
        let marker = try Data(contentsOf: f.marker)
        do { _ = try await f.store.prepareProjectImport(from: f.source); XCTFail("Collision accepted") }
        catch {}
        XCTAssertEqual(try tree(f.imported), destination)
        XCTAssertEqual(try tree(f.source), source)
        XCTAssertEqual(try Data(contentsOf: f.marker), marker)
    }

    func testRejectsCorruptManifestSchemaIDsReferencesAndBlobs() async throws {
        for damage in ["json", "schema", "id", "duplicate", "path", "blob"] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let manifestURL = f.source.appendingPathComponent("project.json")
            var manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
            switch damage {
            case "json": try Data("broken".utf8).write(to: manifestURL)
            case "blob": try Data("changed".utf8).write(to: f.source.appendingPathComponent(manifest.documents[0].relativePath))
            default:
                if damage == "schema" { manifest.schemaVersion += 1 }
                if damage == "id" { manifest.id = WritingProjectID() }
                if damage == "duplicate" { manifest.documents.append(manifest.documents[0]) }
                if damage == "path" { manifest.assets[0].reference = "../outside" }
                try JSONEncoder().encode(manifest).write(to: manifestURL)
            }
            try await assertRejected(f)
        }
    }

    func testRejectsNestedDanglingAndDestinationSymlinks() async throws {
        for location in ["nested", "dangling", "destination", "source"] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let outside = f.root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("untouched".utf8).write(to: outside.appendingPathComponent("sentinel"))
            if location == "source" {
                let saved = f.root.appendingPathComponent("source-saved")
                try FileManager.default.moveItem(at: f.source, to: saved)
                try FileManager.default.createSymbolicLink(at: f.source, withDestinationURL: saved)
            } else {
                let link = location == "destination" ? f.imported : f.source.appendingPathComponent("UserData/link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL:
                    location == "dangling" ? outside.appendingPathComponent("missing") : outside)
            }
            let source = try tree(f.source)
            let marker = try Data(contentsOf: f.marker)
            do { _ = try await f.store.prepareProjectImport(from: f.source); XCTFail("Symlink accepted") }
            catch {}
            XCTAssertEqual(try tree(f.source), source)
            XCTAssertEqual(try Data(contentsOf: f.marker), marker)
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("sentinel")), Data("untouched".utf8))
            if location != "destination" { XCTAssertFalse(FileManager.default.fileExists(atPath: f.imported.path)) }
        }
    }

    func testRejectsNonRegularManifestBeforeReadingIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let manifest = f.source.appendingPathComponent("project.json")
        try FileManager.default.removeItem(at: manifest)
        XCTAssertEqual(mkfifo(manifest.path, mode_t(0o600)), 0)
        let readMarker = f.root.appendingPathComponent("unexpected-read")
        let store = ProjectStore(root: f.target, fileSystem: ManifestReadTrap(
            manifest: manifest, marker: readMarker))
        let marker = try Data(contentsOf: f.marker)
        do { _ = try await store.prepareProjectImport(from: f.source); XCTFail("FIFO accepted") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: readMarker.path), "Reading a FIFO can block indefinitely")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.imported.path))
        XCTAssertEqual(try Data(contentsOf: f.marker), marker)
    }

    func testCopyVerificationSourceChangeAndCancellationFailuresPreserveOwner() async throws {
        for fault in ImportFault.allCases {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var source = try tree(f.source)
            let marker = try Data(contentsOf: f.marker)
            let current = try tree(f.target.appendingPathComponent(f.current.id.rawValue.uuidString))
            let store = ProjectStore(root: f.target, fileSystem: ImportFaultFiles(
                source: f.source, target: f.target, fault: fault))
            do {
                _ = try await Task { try await store.prepareProjectImport(from: f.source) }.value
                XCTFail("Fault accepted: \(fault)")
            } catch {
                if fault == .cancel { XCTAssertTrue(error is CancellationError) }
            }
            if fault == .sourceChange { source["UserData/decisions.json"] = Data("writer's newer decision".utf8) }
            XCTAssertEqual(try tree(f.source), source)
            XCTAssertEqual(try Data(contentsOf: f.marker), marker)
            XCTAssertEqual(try tree(f.target.appendingPathComponent(f.current.id.rawValue.uuidString)), current)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.imported.path))
        }
    }

    private struct Fixture {
        let root: URL, source: URL, target: URL
        let project: WritingProject, previous: WritingProject, current: WritingProject
        let store: ProjectStore
        var imported: URL { target.appendingPathComponent(project.id.rawValue.uuidString) }
        var marker: URL { target.appendingPathComponent("active-project.json") }
    }

    private func fixture(mode: WritingMode = .general) async throws -> Fixture {
        let root = try temporaryProjectRoot().resolvingSymlinksInPath()
        let sourceRoot = root.appendingPathComponent("development/Projects")
        let sourceStore = ProjectStore(root: sourceRoot)
        var project = projectFixture()
        project.mode = mode
        try await sourceStore.save(project)
        try await sourceStore.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
        let previous = try await sourceStore.load(id: project.id)
        project.documents[0].body += "Updated 한글\r\n"
        project.trashedDocumentIDs = [project.documents[1].id]
        try await sourceStore.save(project)
        let source = sourceRoot.appendingPathComponent(project.id.rawValue.uuidString)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("UserData/empty"), withIntermediateDirectories: true)
        try Data(#"{"decision":"원문"}"#.utf8).write(to: source.appendingPathComponent("UserData/decisions.json"))
        try Data([0, 255, 1]).write(to: source.appendingPathComponent("opaque.bin"))
        try FileManager.default.removeItem(at: sourceRoot.appendingPathComponent(".store.lock"))
        let target = root.appendingPathComponent("container/Documents/Purlory/Projects")
        let store = ProjectStore(root: target)
        let current = projectFixture()
        try await store.save(current)
        try await store.activate(id: current.id)
        return Fixture(root: root, source: source, target: target,
            project: project, previous: previous, current: current, store: store)
    }

    private func assertRejected(_ f: Fixture) async throws {
        let source = try tree(f.source)
        let marker = try Data(contentsOf: f.marker)
        do { _ = try await f.store.prepareProjectImport(from: f.source); XCTFail("Damaged project accepted") }
        catch {}
        XCTAssertEqual(try tree(f.source), source)
        XCTAssertEqual(try Data(contentsOf: f.marker), marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.imported.path))
    }

    private func tree(_ root: URL) throws -> [String: Data] {
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        var result: [String: Data] = [:]
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true {
                let prefix = root.resolvingSymlinksInPath().path + "/"
                let path = url.resolvingSymlinksInPath().path
                XCTAssertTrue(path.hasPrefix(prefix))
                result[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }
}

private struct ManifestReadTrap: ProjectFileSystem {
    let manifest: URL, marker: URL
    private let real = LocalProjectFileSystem()
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws { try real.writeAtomically(data, to: url) }
    func read(_ url: URL) throws -> Data {
        if url.resolvingSymlinksInPath() == manifest.resolvingSymlinksInPath() {
            try Data().write(to: marker)
            throw CocoaError(.fileReadUnknown)
        }
        return try real.read(url)
    }
}

private enum ImportFault: CaseIterable { case copy, verification, corruptCopy, sourceChange, cancel }
private struct ImportFaultFiles: ProjectFileSystem {
    let source: URL, target: URL, fault: ImportFault
    private let real = LocalProjectFileSystem()
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func read(_ url: URL) throws -> Data {
        if fault == .verification && url.resolvingSymlinksInPath().path.hasPrefix(target.resolvingSymlinksInPath().path + "/") && url.lastPathComponent == "decisions.json" {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try real.read(url)
    }
    func writeAtomically(_ data: Data, to url: URL) throws {
        guard url.lastPathComponent == "decisions.json" else { return try real.writeAtomically(data, to: url) }
        if fault == .copy { throw CocoaError(.fileWriteOutOfSpace) }
        try real.writeAtomically(fault == .corruptCopy ? Data("damaged copy".utf8) : data, to: url)
        if fault == .sourceChange { try Data("writer's newer decision".utf8).write(to: source.appendingPathComponent("UserData/decisions.json")) }
        if fault == .cancel { withUnsafeCurrentTask { $0?.cancel() } }
    }
}
