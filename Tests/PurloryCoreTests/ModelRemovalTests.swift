@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ModelRemovalTests: XCTestCase {
    private func fixture() throws -> (URL, ModelInstallManifest, ModelInstallationStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-Removal-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pin = ModelInstallManifest(id: "fixture/model", revision: String(repeating: "a", count: 40), files:
            ["config.json", "tokenizer.json", "model.safetensors"].map { .init(path: $0, size: 3,
                digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", algorithm: .sha256) })
        return (root, pin, ModelInstallationStore(root: root.appendingPathComponent("Models")))
    }
    private let download: ModelInstallationStore.Download = { _, _, destination in try Data("abc".utf8).write(to: destination) }
    func testRemovalClearsOnlyOwnedModelsAndIsIdempotent() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let manuscript = root.appendingPathComponent("manuscript.txt"); try Data("keep".utf8).write(to: manuscript)
        let intelligence = root.appendingPathComponent("Intelligence"); try FileManager.default.createDirectory(at: intelligence, withIntermediateDirectories: true)
        let directory = try await store.install(pin, download: download)
        let ids = await store.ownedModelIDs(); XCTAssertEqual(ids, [pin.id])
        try await store.remove(pin.id); try await store.remove(pin.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try String(contentsOf: manuscript, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: intelligence.path))
        let state = await store.state(for: pin); XCTAssertEqual(state, .missing)
    }
    func testRemovalJoinsCancelledTransferAndPreventsLatePublication() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "transfer started"), removing = expectation(description: "removal begins")
        let gate = RemovalGate()
        let install = Task { try await store.install(pin) { _, _, destination in
            started.fulfill(); await gate.wait(); try Data("abc".utf8).write(to: destination)
        } }
        await fulfillment(of: [started], timeout: 5)
        let removal = Task { try await store.remove(pin.id, onRetire: { removing.fulfill() }) }
        await fulfillment(of: [removing], timeout: 5)
        let state = await store.state(for: pin); XCTAssertEqual(state, .removing)
        if state == .removing {
            do { _ = try await store.install(pin, download: download); XCTFail("Install must be blocked during retirement") } catch {}
        } else { install.cancel() }
        await gate.open(); try await removal.value
        do { _ = try await install.value; XCTFail("Cancelled transfer must not publish") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let final = await store.state(for: pin); XCTAssertEqual(final, .missing)
    }
    func testUnmanagedAndSymlinkDataAbortRemovalWithoutDeletingAnyVersion() async throws {
        for symlink in [false, true] {
            let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = try await store.install(pin, download: download)
            let outside = root.appendingPathComponent("manuscript.txt"); try Data("keep".utf8).write(to: outside)
            let extra = directory.appendingPathComponent("unknown.txt")
            if symlink { try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: outside) }
            else { try Data("keep too".utf8).write(to: extra) }
            do { try await store.remove(pin.id); XCTFail("Unknown data must prevent retirement") } catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
            XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
        }
    }
    func testInterruptedTombstoneCannotLoadAndRemovalRetries() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await store.install(pin, download: download)
        let tombstone = directory.appendingPathExtension("removing")
        try FileManager.default.moveItem(at: directory, to: tombstone)
        let reopened = ModelInstallationStore(root: root.appendingPathComponent("Models"))
        let state = await reopened.state(for: pin); XCTAssertEqual(state, .interrupted)
        do { _ = try await reopened.install(pin, download: download); XCTFail("Pending removal must not reinstall") } catch {}
        try await reopened.remove(pin.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        let installed = try await reopened.install(pin, download: download)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
    }
    func testFailedReplacementPreservesOldInstallation() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await store.install(pin, download: download)
        var target = pin; target.id = "fixture/other"
        do { _ = try await store.replace(pin.id, with: target) { _, _, _ in throw CancellationError() }; XCTFail("Must fail") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let state = await store.state(for: pin); XCTAssertEqual(state, .ready)
    }
    func testSameIDReplacementRetainsNewRevisionAndRejectsStaleMemo() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await store.install(pin, download: download)
        var target = pin; target.revision = String(repeating: "b", count: 40)
        let replacement = try await store.replace(pin.id, with: target, download: download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        let state = await store.state(for: target); XCTAssertEqual(state, .ready)
        try Data("bad".utf8).write(to: replacement.appendingPathComponent("model.safetensors"))
        let corrupt = await store.state(for: target); if case .failed = corrupt {} else { XCTFail("Memo must not cross revisions") }
    }
    func testConflictingTombstonePreservesEveryEarlierVersion() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.install(pin, download: download)
        var next = pin; next.revision = String(repeating: "b", count: 40)
        let second = try await store.install(next, download: download)
        try FileManager.default.copyItem(at: second, to: second.appendingPathExtension("removing"))
        do { try await store.remove(pin.id); XCTFail("Ambiguous retirement must abort") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
    func testEmptyDirectoryBeforeOwnershipIntentCanBeRemoved() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await store.directory(for: pin)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await store.remove(pin.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testConcurrentTargetRemovalCannotPublishSuccessfulReplacement() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.install(pin, download: download)
        var oldTransfer = pin; oldTransfer.revision = String(repeating: "c", count: 40)
        let started = expectation(description: "old transfer"), cancelled = expectation(description: "old transfer cancelled")
        let gate = RemovalGate()
        let transfer = Task { try await store.install(oldTransfer) { _, _, destination in
            started.fulfill()
            while !Task.isCancelled { await Task.yield() }
            cancelled.fulfill(); await gate.wait()
            try Data("abc".utf8).write(to: destination)
        } }
        await fulfillment(of: [started], timeout: 5)
        var target = pin; target.id = "fixture/other"
        let replacementDownload = download
        let replacement = Task { try await store.replace(pin.id, with: target, download: replacementDownload) }
        await fulfillment(of: [cancelled], timeout: 5)
        try await store.remove(target.id)
        await gate.open()
        do { _ = try await replacement.value; XCTFail("Deleted target must not publish success") } catch {}
        _ = try? await transfer.value
    }
}
private actor RemovalGate {
    var opened = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
