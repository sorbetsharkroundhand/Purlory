@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class CompletionMemoryPressureTests: XCTestCase {
    func testPressureClearsGhostCounterAndNamingWithoutChangingPreferences() async throws {
        let suite = "purlory.pressure-preferences.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults)
        settings.modelID = "fixture/model"
        settings.setCompletionEnabled(true)
        settings.ghostContextMode = .rawWithNameAnchor
        let controller = CompletionController(settings: settings)
        controller.documentContextProvider = { DocumentContext(title: "Fixture", kind: .novel) }
        controller.rememberTokenCounter(.init { $0.count }, for: settings.modelID)
        controller.publishCompletion(result(), caretLocation: 3, mode: "story")
        let naming = controller._testInjectNamingTask(folderID: UUID())
        controller.lastContextReport = ContextReport(items: [])
        let persisted = defaults.dictionaryRepresentation()
        controller.setMemoryPressurePaused(true)
        XCTAssertNil(controller.suggestion)
        XCTAssertNil(controller.lastContextReport)
        XCTAssertFalse(controller.isPredicting)
        XCTAssertTrue(naming.isCancelled)
        XCTAssertTrue(controller.namingFolderIDs.isEmpty)
        XCTAssertEqual(controller.effectiveContextCharacters, settings.novelContextCharacters)
        XCTAssertFalse(controller.usesOriginalNameAnchors)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, persisted as NSDictionary)
        XCTAssertEqual(settings.authorization, .enabled)
        XCTAssertEqual(settings.modelID, "fixture/model")
        await naming.value
        controller.shutdown()
    }

    func testPausedRetriesAndLateResultsStayBlockedAndNormalDoesNotReload() async {
        let settings = CompletionSettings()
        settings.setCompletionEnabled(true)
        settings.modelID = "fixture/unapproved"
        let controller = CompletionController(settings: settings)
        controller.setMemoryPressurePaused(true)
        let paused = controller.engineState
        guard case .failed(let message) = paused else { return XCTFail("Pressure needs actionable state") }
        XCTAssertTrue(message.contains("원고 편집"))
        controller.retryEngineLoad()
        controller.preloadEngine()
        controller.noteLoadProgress(1, modelID: settings.modelID)
        controller.publishCompletion(result(), caretLocation: 3, mode: "story")
        controller.rememberTokenCounter(.init { $0.count }, for: settings.modelID)
        controller.noteEdit(prefix: "Fixture text", caretLocation: 12, isComposing: false, caretAtParagraphEnd: true)
        XCTAssertEqual(controller.engineState, paused)
        XCTAssertNil(controller.suggestion)
        let forbidden = expectation(description: "Normal cannot auto-load or publish")
        forbidden.isInverted = true
        controller.setMemoryPressurePaused(false)
        XCTAssertEqual(controller.engineState, .idle)
        let state = controller.engineStateChanges.dropFirst().sink { _ in forbidden.fulfill() }
        await fulfillment(of: [forbidden], timeout: 0.1)
        controller.shutdown()
        withExtendedLifetime(state) {}
    }

    func testPressureCancelsDebouncedCompletionBeforeItStarts() async {
        let settings = CompletionSettings()
        settings.setCompletionEnabled(true)
        settings.debounceMilliseconds = 20
        let controller = CompletionController(settings: settings)
        controller.noteEdit(prefix: "Fixture text", caretLocation: 12, isComposing: false, caretAtParagraphEnd: true)
        controller.setMemoryPressurePaused(true)
        let forbidden = expectation(description: "Cancelled request cannot begin inference")
        forbidden.isInverted = true
        let state = controller.isPredictingChanges.filter { $0 }.sink { _ in forbidden.fulfill() }
        await fulfillment(of: [forbidden], timeout: 0.1)
        XCTAssertFalse(controller.isPredicting)
        controller.shutdown()
        withExtendedLifetime(state) {}
    }

    func testPressureRefusesReplacementBeforeConsentOrInstallationChanges() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = CompletionSettings()
        settings.modelID = ""; settings.setCompletionEnabled(true)
        let controller = CompletionController(settings: settings)
        controller.setMemoryPressurePaused(true)
        let pin = ModelInstallManifest(id: "fixture/model", revision: String(repeating: "a", count: 40), files:
            ["config.json", "tokenizer.json", "model.safetensors"].map { .init(path: $0, size: 3,
                digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", algorithm: .sha256) })
        do {
            try await controller.replaceModel(manifest: pin, store: ModelInstallationStore(root: root), download: { _, _, _ in
                XCTFail("Pressure must refuse before starting a transfer")
                throw CancellationError()
            })
            XCTFail("Replacement must remain blocked")
        } catch { XCTAssertEqual(error as? ModelInstallError, .busy) }
        XCTAssertEqual(settings.authorization, .enabled)
        XCTAssertTrue(settings.autocompleteEnabled)
        XCTAssertEqual(settings.modelID, "")
        XCTAssertEqual(controller.engineState, .failed(CompletionController.memoryPressureMessage))
    }

    func testOverBudgetRefusalReachesUIAndSurvivesTemporaryPressure() async throws {
        let pin = try XCTUnwrap(PinnedModelCatalog.manifest(for: ModelPresets.qwen2_5_1_5B))
        let policy = ModelMemoryPolicy(hardware: .init(physicalBytes: 8 << 30,
            recommendedWorkingSetBytes: 8 << 30, hasUnifiedMemory: true), entries: [
                .init(id: pin.id, revision: pin.revision, peakBytes: 6 << 30,
                      tiers: [.gb8], defaultTiers: [], name: "Oversized fixture")])
        let settings = CompletionSettings()
        settings.setCompletionEnabled(true); settings.modelID = pin.id
        let controller = CompletionController(settings: settings, engine: CompletionEngine(memoryPolicy: policy))
        let refused = expectation(description: "Budget refusal reaches UI before model setup")
        let state = controller.engineStateChanges.first { if case .failed = $0 { return true }; return false }
            .sink { _ in refused.fulfill() }
        controller.preloadEngine()
        await fulfillment(of: [refused], timeout: 1)
        let failure = CompletionController.EngineState.failed(ModelMemoryError.budgetExceeded.localizedDescription)
        XCTAssertEqual(controller.engineState, failure)
        controller.setMemoryPressurePaused(true)
        controller.setMemoryPressurePaused(false)
        XCTAssertEqual(controller.engineState, failure)
        controller.shutdown()
        withExtendedLifetime(state) {}
    }

    private func result() -> CompletionEngine.Completion {
        .init(text: " next", timeToFirstChunk: 0.1, totalTime: 0.2, promptTokensPerSecond: nil,
              generationTokensPerSecond: nil, stoppedAtSentenceBoundary: false, promptTokenCount: 1, reusedPromptTokens: 0)
    }
}
