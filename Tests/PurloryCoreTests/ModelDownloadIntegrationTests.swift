@_spi(Benchmark) @testable import PurloryInference
import Combine
import Foundation
import XCTest
@testable import PurloryCore

@MainActor
final class ModelDownloadIntegrationTests: XCTestCase {
    private func fixture() throws -> (URL, ModelInstallManifest, ModelInstallationStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-Manager-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pin = ModelInstallManifest(id: "fixture/model", revision: String(repeating: "a", count: 40),
            files: ["config.json", "tokenizer.json", "model.safetensors"].map {
                .init(path: $0, size: 3, digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", algorithm: .sha256)
            })
        return (root, pin, ModelInstallationStore(root: root))
    }
    private func manager(_ pin: ModelInstallManifest, _ store: ModelInstallationStore,
                         download: @escaping ModelInstallationStore.Download) -> ModelDownloadManager {
        ModelDownloadManager(store: store, manifestForID: { $0 == pin.id ? pin : nil },
                             download: download, startBlock: { nil })
    }
    private func observe(_ manager: ModelDownloadManager, id: String,
                         matches: @escaping (ModelDownloadManager.State) -> Bool) -> (XCTestExpectation, AnyCancellable) {
        let event = expectation(description: "installation state")
        let subscription = manager.$states.filter { states in
            guard let state = states[id] else { return false }; return matches(state)
        }.prefix(1).sink { _ in event.fulfill() }
        return (event, subscription)
    }
    func testDownloadedStateRequiresVerifiedOwnedInstallation() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(pin, store) { _, _, destination in try Data("abc".utf8).write(to: destination) }
        let (event, subscription) = observe(manager, id: pin.id) { $0 == .downloaded }
        manager.download(pin.id)
        await fulfillment(of: [event], timeout: 5)
        let state = await store.state(for: pin); XCTAssertEqual(state, .ready)
        withExtendedLifetime(subscription) {}
    }
    func testRefreshDetectsCorruptionWithoutReportingDownloaded() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await store.install(pin) { _, _, destination in try Data("abc".utf8).write(to: destination) }
        try Data("bad".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        let manager = manager(pin, store) { _, _, destination in try Data("abc".utf8).write(to: destination) }
        let (event, subscription) = observe(manager, id: pin.id) { if case .failed = $0 { return true }; return false }
        manager.refresh([pin.id])
        XCTAssertEqual(manager.states[pin.id], .verifying)
        await fulfillment(of: [event], timeout: 5)
        XCTAssertNotEqual(manager.states[pin.id], .downloaded)
        withExtendedLifetime(subscription) {}
    }
    func testLateCancelledTransferCannotOverwriteImmediateRetry() async throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = DownloadTestGate(), started = expectation(description: "old transfer")
        let manager = manager(pin, store) { _, file, destination in
            if file.path == "config.json", await gate.takeFirst() { started.fulfill(); await gate.wait() }
            try Data("abc".utf8).write(to: destination)
        }
        manager.download(pin.id)
        await fulfillment(of: [started], timeout: 5)
        let (event, subscription) = observe(manager, id: pin.id) { $0 == .downloaded }
        manager.cancel(pin.id)
        manager.download(pin.id)
        await gate.open()
        await fulfillment(of: [event], timeout: 5)
        let state = await store.state(for: pin); XCTAssertEqual(state, .ready)
        withExtendedLifetime(subscription) {}
    }
    func testUnpinnedModelCannotCreateInstallationData() throws {
        let (root, pin, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(pin, store) { _, _, destination in try Data("abc".utf8).write(to: destination) }
        manager.download("unregistered/model")
        guard case .failed(let message) = manager.states["unregistered/model"] else { return XCTFail("Missing pins must fail locally") }
        XCTAssertTrue(message.contains("고정"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testEngineRejectsUnpinnedModelBeforeMLXSetup() async throws {
        do {
            try await CompletionEngine().preload(parameters: .init(modelID: "unregistered/\(UUID())"))
            XCTFail("Unpinned inference must fail before setup")
        } catch {
            guard case ModelInstallError.metadata = error else { return XCTFail("Expected metadata failure, got \(error)") }
        }
    }
}

private actor DownloadTestGate {
    private var first = true, opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func takeFirst() -> Bool { defer { first = false }; return first }
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
