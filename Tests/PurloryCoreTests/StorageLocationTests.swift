@testable import PurloryStorage
import XCTest
@testable import PurloryCore

@MainActor
final class StorageLocationTests: XCTestCase {
    func testInjectedLocationDoesNotCreateOrRelocateDirectories() throws {
        let root = fixtureRoot()
        let location = PurloryStorageLocation(rootDirectory: root)
        XCTAssertEqual(location.projectsDirectory, root.appendingPathComponent("Projects", isDirectory: true))
        XCTAssertEqual(location.knowledgeDirectory, root.appendingPathComponent("knowledge", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testInjectedRootPreservesManuscriptTrashAndProjectRoundTrips() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = PurloryStorageLocation(rootDirectory: root)
        let store = EntryStore(storageLocation: location)
        store.updateActiveBody("Isolated manuscript")
        let originalID = store.activeID
        store.newEntry()
        store.delete(originalID)
        store.flush()
        let reopened = EntryStore(storageLocation: location)
        XCTAssertEqual(reopened.trash.items.first?.entries.first?.body, "Isolated manuscript")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("entries.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("trash.json").path))

        let project = WritingProject(id: WritingProjectID(), title: "Fixture", mode: .general, documents: [
            .init(id: WritingDocumentID(), title: "Draft", body: "Project manuscript", kind: .manuscript)
        ])
        let projects = ProjectStore(root: location.projectsDirectory)
        try await projects.save(project)
        let loaded = try await projects.load(id: project.id)
        XCTAssertEqual(loaded, project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "Projects/\(project.id.rawValue.uuidString)/project.json").path))
    }

    func testKnowledgeReadWriteAndRemovalStayWithinInjectedRoot() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = PurloryStorageLocation(rootDirectory: root.appendingPathComponent("a"))
        let b = PurloryStorageLocation(rootDirectory: root.appendingPathComponent("b"))
        let id = UUID()
        var sidecar = KnowledgeSidecar(entryID: id)
        sidecar.generation = 4
        sidecar.save(storageLocation: a)
        sidecar.generation = 9
        sidecar.save(storageLocation: b)
        XCTAssertEqual(KnowledgeSidecar.load(entryID: id, storageLocation: a).generation, 4)
        XCTAssertEqual(KnowledgeSidecar.load(entryID: id, storageLocation: b).generation, 9)
        KnowledgeSidecar.remove(entryID: id, storageLocation: a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "a/knowledge/\(id.uuidString).json").path))
        XCTAssertEqual(KnowledgeSidecar.load(entryID: id, storageLocation: b).generation, 9)
    }

    func testStopwordCacheDoesNotCrossRootsWithEqualModificationTimes() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = PurloryStorageLocation(rootDirectory: root.appendingPathComponent("a"))
        let b = PurloryStorageLocation(rootDirectory: root.appendingPathComponent("b"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for (location, text) in [(a, "alpha\n"), (b, "beta\n")] {
            try FileManager.default.createDirectory(at: location.rootDirectory, withIntermediateDirectories: true)
            let file = location.rootDirectory.appendingPathComponent("character-stopwords.txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        XCTAssertEqual(UserStopwords.load(storageLocation: a), ["alpha"])
        XCTAssertEqual(UserStopwords.load(storageLocation: b), ["beta"])
        XCTAssertEqual(UserStopwords.load(storageLocation: a), ["alpha"])
    }

    func testQueuedMetricsUseTheirInjectedRootForLogSummaryAndReset() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = PurloryStorageLocation(rootDirectory: root.appendingPathComponent("a"))
        let b = PurloryStorageLocation(rootDirectory: root.appendingPathComponent("b"))
        AcceptanceMetrics.log(.acceptedFull, mode: "fixture", storageLocation: a)
        AcceptanceMetrics.log(.shown, mode: "fixture", storageLocation: b)
        try await waitUntil {
            AcceptanceMetrics.summarize(storageLocation: a).acceptedFull == 1
                && AcceptanceMetrics.summarize(storageLocation: b).shown == 1
        }
        XCTAssertEqual(AcceptanceMetrics.summarize(storageLocation: a).shown, 0)
        XCTAssertEqual(AcceptanceMetrics.summarize(storageLocation: b).acceptedFull, 0)
        AcceptanceMetrics.reset(storageLocation: a)
        try await waitUntil {
            !FileManager.default.fileExists(atPath: a.rootDirectory.appendingPathComponent("metrics.jsonl").path)
        }
        XCTAssertEqual(AcceptanceMetrics.summarize(storageLocation: b).shown, 1)
    }

    func testJanitorUsesExplicitRootInsteadOfAnotherImageStoreOverride() throws {
        let root = fixtureRoot()
        defer { PurloryImageStore.setDirectoryOverride(nil); try? FileManager.default.removeItem(at: root) }
        let a = PurloryStorageLocation(rootDirectory: root.appendingPathComponent("a"))
        let b = PurloryStorageLocation(rootDirectory: root.appendingPathComponent("b"))
        try FileManager.default.createDirectory(at: a.rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.rootDirectory, withIntermediateDirectories: true)
        PurloryImageStore.setDirectoryOverride(a.rootDirectory)
        let reference = try XCTUnwrap(PurloryImageStore.save(Data("image-a".utf8), ext: "png"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(PurloryImageStore.resolveURL(
            for: reference, under: a.rootDirectory))), Data("image-a".utf8))
        PurloryImageStore.setDirectoryOverride(b.rootDirectory)
        let other = try XCTUnwrap(PurloryImageStore.save(Data("image-b".utf8), ext: "png"))
        var removed: [String] = []
        AssetJanitor.sweep(now: .distantFuture, storageLocation: a, isReferenced: { _ in false }) {
            removed.append($0)
        }
        XCTAssertEqual(removed, [reference])
        XCTAssertFalse(AssetJanitor.hasPendingCandidates(storageLocation: a))
        XCTAssertTrue(AssetJanitor.hasPendingCandidates(storageLocation: b))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(PurloryImageStore.url(for: other))), Data("image-b".utf8))
    }

    private func fixtureRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-location-\(UUID().uuidString)")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for isolated storage IO")
    }
}
