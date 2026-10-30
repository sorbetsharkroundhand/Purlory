@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ModelLifecycleIntegrationTests: XCTestCase {
    private func fixture() throws -> (URL, ModelInstallManifest, ModelInstallationStore, CompletionSettings) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-Lifecycle-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pin = ModelInstallManifest(id: "fixture/model", revision: String(repeating: "a", count: 40), files:
            ["config.json", "tokenizer.json", "model.safetensors"].map { .init(path: $0, size: 3,
                digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", algorithm: .sha256) })
        let suite = "Purlory.Lifecycle.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults)
        settings.modelID = pin.id; settings.authorName = "Writer"; settings.maxTokens = 28
        return (root, pin, ModelInstallationStore(root: root.appendingPathComponent("Models")), settings)
    }
    private let download: ModelInstallationStore.Download = { _, _, destination in try Data("abc".utf8).write(to: destination) }
    func testActiveRemovalLeavesDurableNoModelAndPreservesWritingPreferences() async throws {
        let (root, pin, store, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.install(pin, download: download)
        settings.setCompletionEnabled(true)
        let controller = CompletionController(settings: settings)
        controller.lastContextReport = ContextReport(items: [.init(kind: .meta, text: "old")], entryID: nil, generation: 1)
        try await controller.removeModel(pin.id, store: store)
        XCTAssertEqual(settings.modelID, ""); XCTAssertFalse(settings.autocompleteEnabled)
        XCTAssertEqual(settings.authorization, .disabled)
        XCTAssertEqual(settings.authorName, "Writer"); XCTAssertEqual(settings.maxTokens, 28)
        XCTAssertNil(controller.lastContextReport); XCTAssertNil(controller.suggestion)
        XCTAssertEqual(controller.engineState, .idle)
        controller.noteEdit(prefix: "한글 원고", caretLocation: 5, isComposing: true, caretAtParagraphEnd: true)
        XCTAssertFalse(controller.isPredicting)
    }
    func testFailedRemovalPreservesSelectionAndLeavesCompletionStopped() async throws {
        let (root, pin, store, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await store.install(pin, download: download)
        let unknown = directory.appendingPathComponent("manuscript.txt"); try Data("keep".utf8).write(to: unknown)
        settings.setCompletionEnabled(true)
        let controller = CompletionController(settings: settings)
        do { try await controller.removeModel(pin.id, store: store); XCTFail("Unknown data must stop removal") } catch {}
        XCTAssertEqual(settings.modelID, pin.id); XCTAssertFalse(settings.autocompleteEnabled)
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "keep")
        XCTAssertEqual(controller.engineState, .idle)
    }
    func testReplacementCommitsOnlyVerifiedTargetAndDropsPriorContext() async throws {
        let (root, pin, store, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await store.install(pin, download: download)
        let controller = CompletionController(settings: settings)
        var target = pin; target.id = "fixture/new"
        try await controller.replaceModel(manifest: target, store: store, download: download)
        XCTAssertEqual(settings.modelID, target.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let state = await store.state(for: target); XCTAssertEqual(state, .ready)
        XCTAssertNil(controller.lastContextReport); XCTAssertEqual(controller.engineState, .idle)
        XCTAssertEqual(settings.authorName, "Writer")
    }
    func testStaleOrDisabledLoadProgressCannotRepublishAnEngineState() throws {
        let (root, pin, _, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        settings.setCompletionEnabled(true)
        let controller = CompletionController(settings: settings)
        controller.noteLoadProgress(0.5, modelID: "fixture/old")
        XCTAssertEqual(controller.engineState, .idle)
        controller.setAutocompleteEnabled(false)
        controller.noteLoadProgress(0.5, modelID: pin.id)
        XCTAssertEqual(controller.engineState, .idle)
    }
    func testEngineUnloadClearsLifetimeIdentityBeforeReuse() async throws {
        let lifetime = ModelLifetimeCoordinator()
        _ = try await lifetime.acquire(modelID: "old", reservingOperation: true)
        await lifetime.finishSwitch(to: "old", succeeded: true, reservingOperation: true)
        let engine = CompletionEngine(memoryPolicy: .current, modelLifetime: lifetime)
        let unloading = Task { try await engine.unload() }
        await lifetime.releaseOperation()
        try await unloading.value
        let admission = try await lifetime.acquire(modelID: "old", reservingOperation: false)
        XCTAssertEqual(admission, .switchOwner)
        await lifetime.finishSwitch(to: "old", succeeded: false, reservingOperation: false)
        let counter = await engine.makeTokenCounter(); XCTAssertNil(counter)
    }
}
