@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
@testable import PurloryStorage
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class MemoryPressureRuntimeTests: XCTestCase {
    func testCriticalUsesExistingEngineAndStoppedOwnerStillDrainsRelease() async throws {
        let lifetime = ModelLifetimeCoordinator()
        _ = try await lifetime.acquire(modelID: "fixture/resident", reservingOperation: true)
        await lifetime.finishSwitch(to: "fixture/resident", succeeded: true, reservingOperation: true)
        let engine = CompletionEngine(memoryPolicy: .current, modelLifetime: lifetime)
        let settings = CompletionSettings(), source = RuntimePressureSource()
        let completion = CompletionController(settings: settings, engine: engine)
        let reader = BackgroundIndexer(engine: engine, settings: settings)
        let runtime = MemoryPressureRuntime(completion: completion, indexer: reader, engine: engine, source: source)
        let paused = expectation(description: "Actual completion admission closes")
        let state = completion.isMemoryPressurePausedChanges.filter { $0 }.prefix(1).sink { _ in paused.fulfill() }
        source.handler?(.critical)
        await fulfillment(of: [paused], timeout: 1)
        runtime.stop()
        let early = expectation(description: "Stop must not skip in-flight release")
        early.isInverted = true
        let draining = Task { await runtime.drain(); early.fulfill() }
        await fulfillment(of: [early], timeout: 0.1)
        await lifetime.releaseOperation()
        await draining.value
        XCTAssertTrue(completion.isMemoryPressurePaused, "Stopped finalizer cannot reopen completion")
        XCTAssertEqual(source.stopCount, 1)
        let admission = try await lifetime.acquire(modelID: "fixture/resident", reservingOperation: false)
        XCTAssertEqual(admission, .switchOwner, "The original engine's resident identity was released")
        await lifetime.finishSwitch(to: "fixture/resident", succeeded: false, reservingOperation: false)
        completion.shutdown(); reader.shutdown()
        withExtendedLifetime(state) {}
    }

    func testWarningBlocksManualBackgroundWithoutPausingForeground() async {
        let settings = CompletionSettings(), engine = CompletionEngine(), source = RuntimePressureSource()
        let completion = CompletionController(settings: settings, engine: engine)
        let reader = BackgroundIndexer(engine: engine, settings: settings)
        let runtime = MemoryPressureRuntime(completion: completion, indexer: reader, engine: engine, source: source)
        defer { runtime.stop(); completion.shutdown(); reader.shutdown() }
        let paused = expectation(description: "Background is paused first")
        let state = reader.manualPhaseChanges.dropFirst().prefix(1).sink { _ in paused.fulfill() }
        source.handler?(.warning)
        await fulfillment(of: [paused], timeout: 1)
        reader.requestPass()
        guard case .blocked = reader.manualPhase else { return XCTFail("Warning cannot admit manual indexing") }
        XCTAssertFalse(completion.isMemoryPressurePaused)
        XCTAssertEqual(completion.engineState, .idle)
        withExtendedLifetime(state) {}
    }

    func testCriticalPreservesNoModelWritingSavingAndOpaqueUserDecisions() async throws {
        let root = try temporaryProjectRoot(), suite = "purlory.pressure-writing.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root), session = ProjectSession(store: store, defaults: defaults)
        var project = projectFixture(); project.userData["future-choice"] = Data([7])
        try await session.saveAndActivate(project)
        let settings = CompletionSettings(defaults: defaults), engine = CompletionEngine(), source = RuntimePressureSource()
        let completion = CompletionController(settings: settings, engine: engine)
        let reader = BackgroundIndexer(engine: engine, settings: settings,
            sidecarPersistence: KnowledgeSidecarRepository(projectStore: store, legacyDirectory: root))
        ContentView.connectProjectConsumers(session: session, completion: completion, indexer: reader)
        let runtime = MemoryPressureRuntime(completion: completion, indexer: reader, engine: engine, source: source)
        defer { runtime.stop(); completion.shutdown(); reader.shutdown() }
        let paused = expectation(description: "Critical received in no-model mode")
        let state = completion.isMemoryPressurePausedChanges.filter { $0 }.prefix(1).sink { _ in paused.fulfill() }
        source.handler?(.critical)
        await fulfillment(of: [paused], timeout: 1)
        let documentID = try XCTUnwrap(session.selectedDocument?.id)
        session.updateSelectedDocumentBody("한글 테스트 원고를 계속 쓴다.")
        try ProjectWriterEditing.perform(.decision(.init(kind: .intentional, targetID: "fixture", statement: "Keep my choice")),
            in: session, identity: XCTUnwrap(session.runtimeIdentity))
        try await session.flush()
        let durable = try await store.load(id: project.id)
        XCTAssertEqual(durable.documents.first(where: { $0.id == documentID })?.body, "한글 테스트 원고를 계속 쓴다.")
        XCTAssertEqual(durable.userData["future-choice"], Data([7]))
        let writer = try WriterDocumentData.decode(durable.userData[WriterDocumentData.key(for: documentID)], documentID: documentID)
        XCTAssertEqual(writer.decisions.first?.statement, "Keep my choice")
        XCTAssertFalse(settings.autocompleteEnabled)
        XCTAssertEqual(settings.modelID, "")
        await runtime.drain()
        withExtendedLifetime(state) {}
    }
}

@MainActor
private final class RuntimePressureSource: MemoryPressureEventSource {
    var handler: (@Sendable (MemoryPressureLevel) -> Void)?
    var stopCount = 0
    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) { self.handler = handler }
    func stop() { stopCount += 1; handler = nil }
}
