@_spi(Benchmark) @testable import PurloryInference
import XCTest
import MLXLMCommon

@testable import PurloryCore

final class GenerationTaskSynchronizerTests: XCTestCase {
    private actor Probe {
        var finished = false

        func markFinished() {
            finished = true
        }
    }

    private actor AdmissionProbe {
        var modelIDs: [String] = []

        func admitted(_ modelID: String) {
            modelIDs.append(modelID)
        }
    }

    func test_cancelAndWait는_내부Task종료까지_기다린다() async {
        let probe = Probe()
        let task = Task<Void, Never> {
            while !Task.isCancelled { await Task.yield() }
            await probe.markFinished()
        }

        await GenerationTaskSynchronizer(task: task).cancelAndWait()

        let didFinish = await probe.finished
        XCTAssertTrue(didFinish)
    }

    func testEarlySentenceStopRetainsFirstTokenTimingWithoutAppendingBufferedText() async throws {
        let probe = Probe()
        let (stream, continuation) = AsyncStream<Generation>.makeStream()
        continuation.yield(.chunk("문장이 끝났다. "))
        let task = Task<Void, Never> {
            while !Task.isCancelled { await Task.yield() }
            continuation.yield(.chunk("버려야 할 다음 문장"))
            continuation.yield(.info(.init(promptTokenCount: 100, generationTokenCount: 2,
                                           promptTime: 0.125, generationTime: 0.05, stopReason: .cancelled)))
            await probe.markFinished()
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        var observation = CompletionEngine.TextObservation()
        guard case .chunk(let chunk) = await iterator.next() else { return XCTFail("Missing first chunk") }
        XCTAssertTrue(observation.append(chunk, stopAtUtteranceEnd: false))

        let info = await GenerationTaskSynchronizer(task: task).cancelAndCollectInfo(from: &iterator)

        XCTAssertEqual(try XCTUnwrap(info).benchmarkTimeToFirstToken, 0.125)
        XCTAssertEqual(observation.rawText, "문장이 끝났다. ")
        let didFinish = await probe.finished
        XCTAssertTrue(didFinish)
    }

    func testFirstTokenTimingRequiresGeneratedTokensAndValidMeasurement() {
        for (tokens, time) in [(0, 0.125), (1, -.infinity), (1, .nan), (1, -0.1)] {
            let info = GenerateCompletionInfo(promptTokenCount: 100, generationTokenCount: tokens,
                                               promptTime: time, generationTime: 0.05)
            XCTAssertNil(info.benchmarkTimeToFirstToken)
        }
        let info = GenerateCompletionInfo(promptTokenCount: 100, generationTokenCount: 1,
                                           promptTime: 0, generationTime: 0.05)
        XCTAssertEqual(info.benchmarkTimeToFirstToken, 0)
    }

    func testFinishedStreamWithoutInfoDoesNotInventFirstTokenTiming() async {
        let (stream, continuation) = AsyncStream<Generation>.makeStream()
        continuation.finish()
        var iterator = stream.makeAsyncIterator()
        let info = await GenerationTaskSynchronizer(task: Task {}).cancelAndCollectInfo(from: &iterator)
        XCTAssertNil(info)
    }

    func test_호출자가이미취소돼도_내부Task종료까지_기다린다() async {
        let probe = Probe()
        let release = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let generation = Task<Void, Never> {
            while !Task.isCancelled { await Task.yield() }
            await release.value
            await probe.markFinished()
        }
        let waiter = Task {
            await GenerationTaskSynchronizer(task: generation).cancelAndWait()
            return await probe.finished
        }

        waiter.cancel()

        let didFinish = await waiter.value
        XCTAssertTrue(didFinish)
    }

    func test_모델전환은_기존사용권과_전환중새요청이_끝날때까지_직렬화된다() async {
        let coordinator = ModelLifetimeCoordinator()
        let probe = AdmissionProbe()

        let initialA = try! await coordinator.acquire(
            modelID: "A", reservingOperation: true)
        XCTAssertEqual(initialA, .switchOwner)
        await coordinator.finishSwitch(
            to: "A", succeeded: true, reservingOperation: true)

        let switchToB = Task {
            let admission = try! await coordinator.acquire(
                modelID: "B", reservingOperation: true)
            await probe.admitted("B")
            return admission
        }
        try? await Task.sleep(for: .milliseconds(20))
        let beforeRelease = await probe.modelIDs
        XCTAssertEqual(beforeRelease, [])

        await coordinator.releaseOperation()
        let bAdmission = await switchToB.value
        XCTAssertEqual(bAdmission, .switchOwner)

        let lateA = Task {
            let admission = try! await coordinator.acquire(
                modelID: "A", reservingOperation: true)
            await probe.admitted("A")
            return admission
        }
        try? await Task.sleep(for: .milliseconds(20))
        let duringSwitch = await probe.modelIDs
        XCTAssertEqual(duringSwitch, ["B"])

        await coordinator.finishSwitch(
            to: "B", succeeded: true, reservingOperation: true)
        try? await Task.sleep(for: .milliseconds(20))
        let whileBIsActive = await probe.modelIDs
        XCTAssertEqual(whileBIsActive, ["B"])

        await coordinator.releaseOperation()
        let lateAAdmission = await lateA.value
        XCTAssertEqual(lateAAdmission, .switchOwner)
        await coordinator.finishSwitch(
            to: "A", succeeded: true, reservingOperation: true)
        await coordinator.releaseOperation()
    }

    func test_실패한모델로드뒤_대기중인새모델이_전환권을받는다() async {
        let coordinator = ModelLifetimeCoordinator()
        let initialB = try! await coordinator.acquire(
            modelID: "B", reservingOperation: false)
        XCTAssertEqual(initialB, .switchOwner)

        let switchToC = Task {
            try! await coordinator.acquire(modelID: "C", reservingOperation: false)
        }
        await Task.yield()
        await coordinator.finishSwitch(
            to: "B", succeeded: false, reservingOperation: false)

        let cAdmission = await switchToC.value
        XCTAssertEqual(cAdmission, .switchOwner)
        await coordinator.finishSwitch(
            to: "C", succeeded: true, reservingOperation: false)
    }

    func test_전환대기중취소된요청은_현재모델을내리지않는다() async {
        let coordinator = ModelLifetimeCoordinator()
        let initialA = try! await coordinator.acquire(
            modelID: "A", reservingOperation: true)
        XCTAssertEqual(initialA, .switchOwner)
        await coordinator.finishSwitch(
            to: "A", succeeded: true, reservingOperation: true)

        let canceledB = Task {
            try await coordinator.acquire(
                modelID: "B", reservingOperation: false)
        }
        await Task.yield()
        canceledB.cancel()
        await coordinator.releaseOperation()

        do {
            _ = try await canceledB.value
            XCTFail("취소된 B 요청이 교체권을 얻으면 안 된다")
        } catch is CancellationError {
            // 기대 경로.
        } catch {
            XCTFail("예상하지 못한 오류: \(error)")
        }

        let stillA = try! await coordinator.acquire(
            modelID: "A", reservingOperation: false)
        XCTAssertEqual(stillA, .current)
    }
}
