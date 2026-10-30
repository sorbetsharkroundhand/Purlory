@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import Combine
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI
@testable import PurloryKoreanBackend

@MainActor
final class WritingDiagnosticsPressureTests: XCTestCase {
    func testCriticalDrainThenNormalCannotReopenOldWorker() async throws {
        let gate = WritingReportNativeGate(blockFirst: true)
        defer { gate.allow.signal() }
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let runtime = WritingDiagnosticsRuntime(worker: worker, observeEnergy: false)
        let holder = WritingReportSnapshotHolder(WritingReportSnapshotHolder.snapshot(String(repeating: "합성 문장. ", count: 1000)))
        runtime.configure(currentSnapshot: { holder.value }); runtime.controller.noteSnapshot(holder.value)
        let report = runtime.controller.scanDocument(holder.value)
        let consuming = Task { for await _ in report { } }
        await fulfillment(of: [gate.started], timeout: 3)
        let releasing = expectation(description: "Native release started")
        let observation = runtime.$isReleasingNative.filter { $0 }.prefix(1).sink { _ in releasing.fulfill() }
        let critical = Task { await runtime.setMemoryPressure(.critical) }
        await fulfillment(of: [releasing], timeout: 1)
        runtime.noteMemoryPressure(.normal)
        XCTAssertTrue(runtime.isReleasingNative)
        XCTAssertEqual(runtime.controller.state.status, .paused)
        holder.value = WritingReportSnapshotHolder.snapshot("다음 프로젝트 원고")
        runtime.controller.noteSnapshot(holder.value)
        XCTAssertEqual(runtime.controller.state.status, .paused)
        XCTAssertEqual(gate.counts.analyzed, 1); XCTAssertEqual(gate.counts.closed, 0)
        gate.allow.signal()
        await critical.value; await consuming.value
        XCTAssertFalse(runtime.isReleasingNative)
        XCTAssertEqual(gate.counts.closed, 1)
        XCTAssertEqual(gate.counts.analyzed, 1, "No old report work is admitted after drain")
        XCTAssertFalse(gate.counts.usedMainThread)
        XCTAssertEqual(holder.value.body, "다음 프로젝트 원고")
        await runtime.prepareForTermination()
        withExtendedLifetime(observation) { }
    }

    func testForegroundObserverCompositionPreservesLegacyCallback() throws {
        let suite = "purlory.writing-observers.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let completion = CompletionController(settings: CompletionSettings(defaults: defaults), engine: CompletionEngine())
        let first = NSObject(), second = NSObject()
        var legacy: [Bool] = [], indexer: [Bool] = [], writing: [Bool] = []
        completion.foregroundCompletionDidChange = { legacy.append($0) }
        completion.observeForegroundCompletion(owner: first) { indexer.append($0) }
        completion.observeForegroundCompletion(owner: second) { writing.append($0) }
        completion.observeForegroundCompletion(owner: second) { writing.append($0) }
        legacy.removeAll(); indexer.removeAll(); writing.removeAll()
        completion.shutdown()
        XCTAssertEqual(legacy, [false]); XCTAssertEqual(indexer, [false]); XCTAssertEqual(writing, [false])
        withExtendedLifetime((first, second)) { }
    }

    func testNormalCannotResumeWritingBeforeSharedModelReleaseFinishes() async throws {
        let lifetime = ModelLifetimeCoordinator()
        _ = try await lifetime.acquire(modelID: "fixture/shared", reservingOperation: true)
        await lifetime.finishSwitch(to: "fixture/shared", succeeded: true, reservingOperation: true)
        let engine = CompletionEngine(memoryPolicy: .current, modelLifetime: lifetime)
        let suite = "purlory.writing-shared-drain.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let completion = CompletionController(settings: CompletionSettings(defaults: defaults), engine: engine)
        let indexer = BackgroundIndexer(engine: engine, settings: completion.settings)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: WritingReportNativeGate(blockFirst: false))
        let writing = WritingDiagnosticsRuntime(worker: worker, observeEnergy: false)
        let source = WritingTestPressureSource()
        let monitor = MemoryPressureRuntime(completion: completion, indexer: indexer, engine: engine, source: source, writingDiagnostics: writing)
        let paused = expectation(description: "Shared release closes completion")
        let observation = completion.isMemoryPressurePausedChanges.filter { $0 }.prefix(1).sink { _ in paused.fulfill() }
        source.handler?(.critical); await fulfillment(of: [paused], timeout: 1)
        await writing.setMemoryPressure(.critical)
        writing.noteMemoryPressure(.normal)
        XCTAssertTrue(completion.isMemoryPressurePaused)
        XCTAssertEqual(writing.controller.state.status, .paused, "Native drain alone does not reopen optional work while the shared release is blocked")
        let resumed = expectation(description: "Shared release finally reopens completion")
        let resumedObservation = completion.isMemoryPressurePausedChanges.dropFirst().filter { !$0 }.prefix(1).sink { _ in resumed.fulfill() }
        source.handler?(.normal)
        await lifetime.releaseOperation()
        await fulfillment(of: [resumed], timeout: 2)
        await monitor.drain()
        XCTAssertNotEqual(writing.controller.state.status, .paused)
        monitor.stop(); await writing.prepareForTermination(); completion.shutdown(); indexer.shutdown()
        withExtendedLifetime((observation, resumedObservation)) { }
    }

    func testSharedMonitorPreservesCompletionAndIndexerConsumers() async throws {
        let suite = "purlory.writing-pressure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults), engine = CompletionEngine()
        let completion = CompletionController(settings: settings, engine: engine)
        let indexer = BackgroundIndexer(engine: engine, settings: settings)
        let gate = WritingReportNativeGate(blockFirst: false)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let writing = WritingDiagnosticsRuntime(worker: worker, observeEnergy: false)
        let source = WritingTestPressureSource()
        let runtime = MemoryPressureRuntime(completion: completion, indexer: indexer, engine: engine,
            source: source, writingDiagnostics: writing)
        let paused = expectation(description: "Existing foreground pressure consumer")
        let observation = completion.isMemoryPressurePausedChanges.filter { $0 }.prefix(1).sink { _ in paused.fulfill() }
        source.handler?(.critical)
        await fulfillment(of: [paused], timeout: 1)
        XCTAssertEqual(writing.controller.state.status, .paused)
        indexer.requestPass()
        guard case .blocked = indexer.manualPhase else { return XCTFail("Indexer still receives pressure") }
        XCTAssertEqual(source.startCount, 1, "There is one pressure monitor")
        runtime.stop(); await runtime.drain(); await writing.prepareForTermination()
        completion.shutdown(); indexer.shutdown()
        withExtendedLifetime(observation) { }
    }
}

@MainActor
private final class WritingTestPressureSource: MemoryPressureEventSource {
    var handler: (@Sendable (MemoryPressureLevel) -> Void)?
    var startCount = 0
    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) { startCount += 1; self.handler = handler }
    func stop() { handler = nil }
}
