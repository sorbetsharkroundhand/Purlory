@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class GhostContextRuntimeTests: XCTestCase {
    @MainActor
    func testProjectCompositionActivatesPreparationOnlyAfterExplicitBOptIn() async throws {
        let root = try temporaryProjectRoot(), suite = "purlory.context-bridge.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root), session = ProjectSession(store: store, defaults: defaults)
        try await session.saveAndActivate(projectFixture())
        let settings = CompletionSettings(defaults: defaults)
        let completion = CompletionController(settings: settings)
        var foregroundEvents: [Bool] = []
        completion.foregroundCompletionDidChange = { foregroundEvents.append($0) }
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings,
            sidecarPersistence: KnowledgeSidecarRepository(projectStore: store, legacyDirectory: root))
        defer { indexer.shutdown() }
        ContentView.connectProjectConsumers(session: session, completion: completion, indexer: indexer)
        XCTAssertNotNil(completion.originalNameAnchorsProvider)
        completion.prepareForProjectTransition()
        XCTAssertEqual(foregroundEvents, [false], "Project composition preserves the existing foreground consumer")
        completion.changeContextMode(to: .rawWithNameAnchor)
        XCTAssertFalse(indexer.originalNameAnchorsEnabled)
        settings.setCompletionEnabled(true)
        completion.contextConfigurationDidChange?()
        XCTAssertTrue(indexer.originalNameAnchorsEnabled)
        completion.setAutocompleteEnabled(false)
        XCTAssertFalse(indexer.originalNameAnchorsEnabled)
        XCTAssertNil(indexer.originalNameAnchors)
    }

    @MainActor
    func testAcceptanceRetainsOriginalStrategyLatencyAndOpportunity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purlory-context-metrics-\(UUID())")
        let suite = "purlory.context.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults)
        let controller = CompletionController(settings: settings, metricsStorageLocation: .init(rootDirectory: root))
        let result = CompletionEngine.Completion(text: " 첫째 둘째", timeToFirstChunk: 0.125,
            totalTime: 0.5, promptTokensPerSecond: nil, generationTokensPerSecond: nil,
            stoppedAtSentenceBoundary: false, promptTokenCount: 10, reusedPromptTokens: 0)
        controller.publishCompletion(result, caretLocation: 3, mode: "story", contextMode: .rawWithNameAnchor, modelID: "fixture/model")
        settings.ghostContextMode = .current
        XCTAssertEqual(controller.acceptWord(insertionLocation: 3), " 첫째")
        XCTAssertEqual(controller.acceptSuggestion(), " 둘째")
        await AcceptanceMetrics.flush()
        let text = try String(contentsOf: root.appendingPathComponent("metrics.jsonl"), encoding: .utf8)
        let rows = try text.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, ["shown", "accepted_word", "accepted_full"])
        XCTAssertEqual(Set(rows.compactMap { $0["opportunityID"] as? String }).count, 1)
        for row in rows {
            XCTAssertEqual(row["contextMode"] as? String, "B")
            XCTAssertEqual(row["latencyMs"] as? Int, 500)
            XCTAssertEqual(row["firstChunkMs"] as? Int, 125)
            XCTAssertEqual(row["modelID"] as? String, "fixture/model")
        }
        XCTAssertFalse(text.contains("첫째"))
    }

    @MainActor
    func testStrategyChangeDismissesOldSuggestionAndReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purlory-context-dismiss-\(UUID())")
        let suite = "purlory.context.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults)
        let controller = CompletionController(settings: settings, metricsStorageLocation: .init(rootDirectory: root))
        let result = CompletionEngine.Completion(text: " 다음", timeToFirstChunk: nil,
            totalTime: 0.25, promptTokensPerSecond: nil, generationTokensPerSecond: nil,
            stoppedAtSentenceBoundary: false, promptTokenCount: 10, reusedPromptTokens: 0)
        controller.publishCompletion(result, caretLocation: 3, mode: "fast", contextMode: .raw)
        controller.lastContextReport = ContextReport(items: [], contextMode: .raw)
        controller.changeContextMode(to: .rawWithNameAnchor)
        XCTAssertNil(controller.lastContextReport)
        XCTAssertFalse(controller.hasSuggestion)
        XCTAssertEqual(settings.parameters.ghostContextMode, .rawWithNameAnchor)
        await AcceptanceMetrics.flush()
        let text = try String(contentsOf: root.appendingPathComponent("metrics.jsonl"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"dismissed\""))
        XCTAssertFalse(text.contains("\"contextMode\":\"B\""))
    }

    @MainActor
    func testSettingsDefaultAndPersistedModeRequireSelectedTokenizerForExpansion() throws {
        let suite = "purlory.context.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults)
        settings.modelID = "fixture/model"
        let controller = CompletionController(settings: settings)
        controller.documentContextProvider = { .init(title: "Draft", kind: .novel) }
        XCTAssertEqual(settings.ghostContextMode, .current)
        settings.ghostContextMode = .raw
        let snapshot = settings.parameters
        XCTAssertEqual(controller.effectiveContextCharacters, settings.novelContextCharacters)
        controller.rememberTokenCounter(TokenCounter { $0.count }, for: "other/model")
        XCTAssertEqual(controller.effectiveContextCharacters, settings.novelContextCharacters)
        controller.rememberTokenCounter(TokenCounter { $0.count }, for: settings.modelID)
        XCTAssertEqual(controller.effectiveContextCharacters, 8_000)
        controller.publishCompletion(.empty, caretLocation: 0, mode: "story", contextMode: .raw,
            modelID: settings.modelID)
        XCTAssertEqual(controller.effectiveContextCharacters, 8_000, "A completed request must retain its selected tokenizer")
        settings.ghostContextMode = .current
        XCTAssertEqual(snapshot.ghostContextMode, .raw)
        XCTAssertEqual(controller.effectiveContextCharacters, settings.novelContextCharacters)
        settings.ghostContextMode = .rawWithNameAnchor
        XCTAssertEqual(CompletionSettings(defaults: defaults).ghostContextMode, .rawWithNameAnchor)
        defaults.set("invalid", forKey: "completion.ghostContextMode")
        XCTAssertEqual(CompletionSettings(defaults: defaults).ghostContextMode, .current)
    }

    func testLegacyLogsRemainReadableAndContextMeasurementsAreGrouped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purlory-context-summary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = PurloryStorageLocation(rootDirectory: root)
        AcceptanceMetrics.log(.shown, mode: "old\"mode", latencyMs: 999, storageLocation: location)
        let opportunity = AcceptanceMetrics.Opportunity(mode: "story", contextMode: .raw,
            latencyMs: 150, firstChunkMs: 100, modelID: nil)
        AcceptanceMetrics.log(.shown, opportunity: opportunity, storageLocation: location)
        AcceptanceMetrics.log(.dismissed, opportunity: opportunity, storageLocation: location)
        await AcceptanceMetrics.flush()
        let summary = AcceptanceMetrics.summarize(storageLocation: location)
        XCTAssertEqual(summary.shown, 2)
        XCTAssertEqual(summary.byContextMode[.raw]?.shown, 1)
        XCTAssertEqual(summary.byContextMode[.raw]?.dismissed, 1)
        XCTAssertEqual(summary.byContextMode[.raw]?.latencyP50Ms, 150)
        XCTAssertNil(summary.byContextMode[.current])
    }
}
