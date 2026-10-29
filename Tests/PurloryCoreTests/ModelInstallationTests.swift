@_spi(Benchmark) @testable import PurloryInference
import Foundation
import XCTest
@testable import PurloryCore

final class ModelInstallationTests: XCTestCase {
    private let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private func manifest(revision: String = String(repeating: "a", count: 40)) -> ModelInstallManifest {
        .init(id: "fixture/model", revision: revision, files: ["config.json", "tokenizer.json", "model.safetensors"].map {
            .init(path: $0, size: 3, digest: sha, algorithm: .sha256)
        })
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-Install-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private let download: ModelInstallationStore.Download = { _, _, destination in
        try Data("abc".utf8).write(to: destination)
    }

    func testReadyRequiresEveryPinnedFileAndExactReceipt() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelInstallationStore(root: root), pin = manifest()
        let before = await store.state(for: pin); XCTAssertEqual(before, .missing)
        let directory = try await store.install(pin, download: download)
        let ready = await store.state(for: pin); XCTAssertEqual(ready, .ready)
        try Data("bad".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        let corrupt = await store.state(for: pin); XCTAssertNotEqual(corrupt, .ready)
        try Data("abc".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        var changed = pin; changed.files[0].digest = String(repeating: "0", count: 64)
        let changedState = await store.state(for: changed); XCTAssertNotEqual(changedState, .ready)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("tokenizer.json"))
        let partial = await store.state(for: pin); XCTAssertNotEqual(partial, .ready)
    }

    func testInterruptedInstallRecoversAndRetriesVerifiedStaging() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pin = manifest(), store = ModelInstallationStore(root: root)
        do {
            _ = try await store.install(pin) { _, file, destination in
                if file.path != "config.json" { throw CocoaError(.fileWriteUnknown) }
                try Data("abc".utf8).write(to: destination)
            }
            XCTFail("Incomplete transfer must fail")
        } catch {}
        let relaunched = ModelInstallationStore(root: root)
        let interrupted = await relaunched.state(for: pin); XCTAssertEqual(interrupted, .interrupted)
        _ = try await relaunched.install(pin) { _, file, destination in
            guard file.path != "config.json" else { throw CocoaError(.fileReadUnknown) }
            try Data("abc".utf8).write(to: destination)
        }
        let ready = await relaunched.state(for: pin); XCTAssertEqual(ready, .ready)
    }

    func testChangedRevisionCannotReuseAnotherReadyInstallation() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelInstallationStore(root: root), old = manifest()
        let previous = try await store.install(old, download: download)
        let next = manifest(revision: String(repeating: "b", count: 40))
        let notReady = await store.state(for: next); XCTAssertEqual(notReady, .missing)
        do { _ = try await store.install(next) { _, _, _ in throw CocoaError(.fileWriteUnknown) } }
        catch {}
        let oldState = await store.state(for: old); XCTAssertEqual(oldState, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.appendingPathComponent("model.safetensors").path))
    }

    func testSymlinkEscapeCannotBecomeReadyOrDamageOutsideData() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("manuscript.txt")
        try Data("original manuscript".utf8).write(to: outside)
        let store = ModelInstallationStore(root: root.appendingPathComponent("Models")), pin = manifest()
        do {
            _ = try await store.install(pin) { _, _, destination in
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
            }
            XCTFail("Symlink must be rejected")
        } catch {
            guard case ProjectStoreError.unsafePath = error else {
                return XCTFail("Expected path rejection, got \(error)")
            }
        }
        let state = await store.state(for: pin); XCTAssertNotEqual(state, .ready)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original manuscript")
    }

    func testGitBlobIntegrityIncludesTheHeader() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var pin = manifest()
        pin.files[0].algorithm = .gitBlobSHA1
        pin.files[0].digest = "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f"
        let store = ModelInstallationStore(root: root)
        _ = try await store.install(pin, download: download)
        let state = await store.state(for: pin); XCTAssertEqual(state, .ready)
    }

    func testConcurrentRequestsJoinWithoutAnotherTransfer() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelInstallationStore(root: root), pin = manifest(), gate = InstallTestGate()
        let started = expectation(description: "first transfer"), joined = expectation(description: "joined state")
        let first = Task {
            try await store.install(pin) { _, file, destination in
                if file.path == "config.json" { started.fulfill(); await gate.wait() }
                try Data("abc".utf8).write(to: destination)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let second = Task {
            try await store.install(pin, download: { _, _, _ in throw CocoaError(.fileWriteUnknown) },
                                    onState: { _, _ in joined.fulfill() })
        }
        await fulfillment(of: [joined], timeout: 2)
        await gate.open()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, b)
        let state = await store.state(for: pin); XCTAssertEqual(state, .ready)
    }

    func testUnlistedWeightsCannotBecomeReadyAndRetryReplacesThem() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelInstallationStore(root: root), pin = manifest()
        let directory = try await store.install(pin, download: download)
        let extra = directory.appendingPathComponent("unverified.safetensors")
        try Data("bad".utf8).write(to: extra)
        let invalid = await store.state(for: pin); XCTAssertNotEqual(invalid, .ready)
        _ = try await store.install(pin, download: download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extra.path))
    }

    func testWeightIndexCannotReferenceAnUnpinnedShard() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var pin = manifest()
        let index = Data("{\"weight_map\":{\"a\":\"missing.safetensors\"}}".utf8)
        pin.files.append(.init(path: "model.safetensors.index.json", size: Int64(index.count),
                               digest: "7bf81cfd1eb436e8f8b10d2855e188583d9d0e4751cbd59064f2bdef1a8d9921", algorithm: .sha256))
        let store = ModelInstallationStore(root: root)
        do {
            _ = try await store.install(pin) { _, file, destination in
                try (file.path.hasSuffix("index.json") ? index : Data("abc".utf8)).write(to: destination)
            }
            XCTFail("A missing indexed shard must prevent publication")
        } catch {}
        let state = await store.state(for: pin); XCTAssertNotEqual(state, .ready)
    }

    func testUnownedDirectoryCollisionsPreserveManuscripts() async throws {
        for staged in [false, true] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ModelInstallationStore(root: root), pin = manifest()
            let final = try await store.directory(for: pin)
            let collision = staged ? final.appendingPathExtension("partial") : final
            try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
            let manuscript = collision.appendingPathComponent("manuscript.txt")
            try Data("writer-owned text".utf8).write(to: manuscript)
            do { _ = try await store.install(pin, download: download); XCTFail("Unowned data must prevent replacement") }
            catch {}
            XCTAssertEqual(try String(contentsOf: manuscript, encoding: .utf8), "writer-owned text")
        }
    }

    func testEmptyDirectoryLeftBeforeIntentWriteCanRetry() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelInstallationStore(root: root), pin = manifest()
        let stage = try await store.directory(for: pin).appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        _ = try await store.install(pin, download: download)
        let ready = await store.state(for: pin); XCTAssertEqual(ready, .ready)
    }

    func testCancellationCannotPublishLateSuccessfulTransfer() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelInstallationStore(root: root), pin = manifest(), gate = InstallTestGate()
        let started = expectation(description: "transfer started")
        let task = Task {
            try await store.install(pin) { _, _, destination in
                started.fulfill()
                await gate.wait()
                try Data("abc".utf8).write(to: destination)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await store.cancel(pin.id)
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled install must not publish") } catch {}
        let relaunched = ModelInstallationStore(root: root)
        let state = await relaunched.state(for: pin); XCTAssertNotEqual(state, .ready)
    }
}

private actor InstallTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
