@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

actor AskTestPause {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var emit: (@Sendable (String) throws -> Void)?
    init(_ started: XCTestExpectation, cancelled: XCTestExpectation? = nil) { self.started = started; self.cancelled = cancelled }
    func run(emit: @escaping @Sendable (String) throws -> Void) async {
        self.emit = emit
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        } onCancel: { self.cancelled?.fulfill() }
    }
    func send(_ value: String) throws { try emit?(value) }
    func release() { continuation?.resume(); continuation = nil; emit = nil }
}

@MainActor
final class AskPurloryControllerTests: XCTestCase {
    private func input(_ f: LegacyBoundaryFixture) throws -> SourceSearchInput {
        .init(query: "original", project: try XCTUnwrap(f.session.activeProject), origin: try XCTUnwrap(f.session.runtimeIdentity), cursor: 0, scope: .project)
    }
    private func record(_ packet: AskEvidencePacket) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["text": "Answer [S1]", "citations": [["source": "S1", "quote": packet.sources[0].hit.evidence.quote]]]), as: UTF8.self) + "\n"
    }

    func testCancelPreservesValidatedPartialAndDrainsNoncooperativeWorker() async throws {
        let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
        let started = expectation(description: "Answer started"), cancelled = expectation(description: "Answer cancelled")
        let pause = AskTestPause(started, cancelled: cancelled)
        var packet: AskEvidencePacket?
        let model = AskPurloryController(session: f.session, input: try input(f), modelAvailable: true) { value, _ in
            packet = value; return AskAnswerGeneration { emit in await pause.run(emit: emit) }
        }
        defer { model.dismiss() }
        model.ask(question: "What happened?")
        await fulfillment(of: [started], timeout: 2)
        let partial = expectation(description: "Validated partial")
        let sub = model.$blocks.filter { $0.count == 1 }.prefix(1).sink { _ in partial.fulfill() }
        try await pause.send(record(try XCTUnwrap(packet)))
        await fulfillment(of: [partial], timeout: 2)
        model.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(model.status, .cancelled); XCTAssertEqual(model.blocks.count, 1)
        await pause.release()
        await Task.yield()
        XCTAssertEqual(model.status, .cancelled)
        let retired = expectation(description: "Invalidation publishes no old source actions")
        let invalidation = model.$status.filter { $0 == .invalidated }.prefix(1).sink { _ in
            XCTAssertTrue(model.blocks.isEmpty); XCTAssertNil(model.packet); retired.fulfill()
        }
        f.session.updateSelectedDocumentBody("Edited original")
        await fulfillment(of: [retired], timeout: 2)
        withExtendedLifetime((sub, invalidation)) {}
    }

    func testProjectBodyAndABAChangesRetireLatePreparedPackets() async throws {
        let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
        let first = try XCTUnwrap(f.session.selectedDocumentID), second = try XCTUnwrap(f.session.createDocument(title: "Other"))
        f.session.selectDocument(first)
        let started = expectation(description: "Preparation paused"), pause = AskTestPause(started)
        var generated = false
        let model = AskPurloryController(session: f.session, input: try input(f), modelAvailable: true, build: { input in
            let packet = try AskEvidencePacket.prepare(input)
            await pause.run(emit: { _ in }); return packet
        }) { _, _ in generated = true; return AskAnswerGeneration { _ in } }
        defer { model.dismiss() }
        model.ask(question: "Question")
        await fulfillment(of: [started], timeout: 2)
        f.session.selectDocument(second); f.session.selectDocument(first)
        XCTAssertEqual(model.status, .invalidated); XCTAssertTrue(model.blocks.isEmpty)
        await pause.release()
        await Task.yield()
        XCTAssertFalse(generated)
        let edited = AskPurloryController(session: f.session, input: try input(f), modelAvailable: true) { _, _ in AskAnswerGeneration { _ in } }
        f.session.updateSelectedDocumentBody("Changed original")
        XCTAssertEqual(edited.status, .invalidated)
        edited.dismiss()
    }

    func testNoModelForegroundAndPolicyGatesNeverStartOrAutomaticallyResumeAnswers() async throws {
        let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
        var calls = 0
        let model = AskPurloryController(session: f.session, input: try input(f), modelAvailable: false) { _, _ in calls += 1; return AskAnswerGeneration { _ in } }
        defer { model.dismiss() }
        model.ask(question: "Question"); XCTAssertEqual(model.status, .unavailable)
        model.setModelAvailable(true); model.setForegroundBusy(true)
        XCTAssertEqual(model.status, .paused, "An idle question must explain its disabled priority gate")
        model.ask(question: "Question"); XCTAssertEqual(model.status, .paused)
        model.setForegroundBusy(false); model.setPolicyPaused(true)
        model.ask(question: "Question"); XCTAssertEqual(model.status, .paused)
        model.setPolicyPaused(false)
        await Task.yield(); XCTAssertEqual(calls, 0)
        XCTAssertFalse(try SourceSearch.results(query: "original", in: try XCTUnwrap(f.session.activeProject),
            origin: try XCTUnwrap(f.session.selectedDocumentID), cursor: 0, scope: .project).isEmpty)
    }

    func testMalformedStreamKeepsValidatedPrefixAndEachExplicitRetryGetsFreshPacket() async throws {
        let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
        var packets: [UUID] = []
        let model = AskPurloryController(session: f.session, input: try input(f), modelAvailable: true) { packet, _ in
            packets.append(packet.id)
            let line = try self.record(packet)
            return AskAnswerGeneration { emit in try emit(line + "unsupported prose\n") }
        }
        defer { model.dismiss() }
        for _ in 0..<2 {
            let failed = expectation(description: "Invalid response stopped")
            let sub = model.$status.dropFirst().filter { $0 == .failed }.prefix(1).sink { _ in failed.fulfill() }
            model.ask(question: "Question")
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertEqual(model.blocks.count, 1)
            withExtendedLifetime(sub) {}
        }
        XCTAssertEqual(Set(packets).count, 2)
    }

    func testForegroundPolicyAndModelRetirementCancelRunningWorkWithoutAutomaticRestart() async throws {
        for gate in 0..<3 {
            let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
            let started = expectation(description: "Active work"), cancelled = expectation(description: "Priority retirement")
            let pause = AskTestPause(started, cancelled: cancelled)
            var calls = 0
            let model = AskPurloryController(session: f.session, input: try input(f), modelAvailable: true) { _, _ in
                calls += 1; return AskAnswerGeneration { emit in await pause.run(emit: emit) }
            }
            model.ask(question: "Question")
            await fulfillment(of: [started], timeout: 2)
            switch gate {
            case 0: model.setForegroundBusy(true)
            case 1: model.setPolicyPaused(true)
            default: model.setModelAvailable(false)
            }
            await fulfillment(of: [cancelled], timeout: 2)
            XCTAssertFalse(model.canAsk)
            model.setForegroundBusy(false); model.setPolicyPaused(false); model.setModelAvailable(true)
            XCTAssertTrue(model.canAsk)
            await pause.release(); await Task.yield()
            XCTAssertEqual(calls, 1)
            model.dismiss()
        }
    }
}

final class AskPurloryBackendTests: XCTestCase {
    @MainActor
    func testCancellationDrainWaitsForAnUncooperativeProducer() async {
        let started = expectation(description: "Producer entered"), cancelled = expectation(description: "Cancellation delivered")
        let pause = AskTestPause(started, cancelled: cancelled)
        let generation = AskAnswerGeneration { emit in await pause.run(emit: emit) }
        await fulfillment(of: [started], timeout: 2)
        let premature = expectation(description: "Drain cannot finish before producer"); premature.isInverted = true
        let finished = expectation(description: "Producer drained")
        var released = false
        let draining = Task {
            await generation.cancelAndDrain()
            if !released { premature.fulfill() }
            finished.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [premature], timeout: 0.05)
        released = true; await pause.release()
        await fulfillment(of: [finished], timeout: 2)
        await draining.value
    }
    func testReadyReservationNeverLoadsOrClaimsAnotherSwitchOwner() async throws {
        let lifetime = ModelLifetimeCoordinator()
        let empty = await lifetime.reserveReadyOperation(modelID: "a"); XCTAssertFalse(empty)
        _ = try await lifetime.acquire(modelID: "a", reservingOperation: false)
        await lifetime.finishSwitch(to: "a", succeeded: true, reservingOperation: false)
        let ready = await lifetime.reserveReadyOperation(modelID: "a"); XCTAssertTrue(ready)
        await lifetime.releaseOperation()
        _ = try await lifetime.acquire(modelID: "b", reservingOperation: false)
        let retiring = await lifetime.reserveReadyOperation(modelID: "a"); XCTAssertFalse(retiring)
        await lifetime.finishSwitch(to: "b", succeeded: true, reservingOperation: false)
        let wrong = await lifetime.reserveReadyOperation(modelID: "a"); XCTAssertFalse(wrong)
        XCTAssertEqual(lifetime.snapshotCount(), 0)
    }

    func testUnloadedEngineRefusesBeforeModelMetadataOrDownloadAndBudgetNeverTruncates() async {
        let lifetime = ModelLifetimeCoordinator(), engine = CompletionEngine(memoryPolicy: .current, modelLifetime: lifetime)
        do {
            try await engine.streamInstructionIfReady(system: "System", user: "Question", parameters: .init(modelID: "fixture/not-installed"), onChunk: { _ in XCTFail("No inference") })
            XCTFail("A model must already be ready")
        } catch { XCTAssertEqual(error as? CompletionEngine.ReadyInstructionError, .modelUnavailable) }
        XCTAssertEqual(lifetime.snapshotCount(), 0)
        XCTAssertTrue(ReadyInstructionLimits.promptFits(count: 512, budget: 512))
        for (count, budget) in [(513, 512), (0, 512), (-1, 512), (1, 0)] { XCTAssertFalse(ReadyInstructionLimits.promptFits(count: count, budget: budget)) }
    }

    func testBoundedStreamStopsAtFirstDroppedChunkWithoutJoiningTextAcrossAGap() async throws {
        let done = expectation(description: "Producer stopped")
        let generation = AskAnswerGeneration(bufferLimit: 1) { emit in
            defer { done.fulfill() }
            try emit("first"); try emit("dropped"); XCTFail("Overflow must stop immediately")
        }
        await fulfillment(of: [done], timeout: 2)
        var iterator = generation.stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, "first")
        do { _ = try await iterator.next(); XCTFail("Must report the gap") } catch {}
        await generation.cancelAndDrain()
    }
}
