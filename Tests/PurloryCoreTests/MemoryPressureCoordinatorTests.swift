@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class MemoryPressureCoordinatorTests: XCTestCase {
    func testInjectedSourceDeliversPressureAndStopsWithItsOwner() async {
        let source = TestMemoryPressureSource()
        let warning = expectation(description: "Injected warning pauses background")
        let released = expectation(description: "Injected critical releases model")
        var backgroundCalls = 0
        let coordinator = MemoryPressureCoordinator(backgroundPause: {
            if $0 { backgroundCalls += 1; if backgroundCalls == 1 { warning.fulfill() } }
        },
            completionPause: { _ in }, releaseModel: { released.fulfill() })
        coordinator.start(source: source)
        source.handler?(.warning)
        await fulfillment(of: [warning], timeout: 1)
        coordinator.start(source: source)
        source.handler?(.critical)
        await fulfillment(of: [released], timeout: 1)
        coordinator.stop()
        XCTAssertEqual(source.stopCount, 2)
        XCTAssertEqual(backgroundCalls, 2)
        XCTAssertEqual(coordinator.level, .critical)
    }

    func testQueuedEventFromRetiredSourceCannotReleaseAfterRestart() async {
        let retired = TestMemoryPressureSource(), current = TestMemoryPressureSource()
        let stale = expectation(description: "Retired source must not release")
        stale.isInverted = true
        let coordinator = MemoryPressureCoordinator(backgroundPause: { _ in },
            completionPause: { _ in }, releaseModel: { stale.fulfill() })
        coordinator.start(source: retired)
        let queued = retired.handler
        coordinator.stop()
        coordinator.start(source: current)
        queued?(.critical)
        await fulfillment(of: [stale], timeout: 0.1)
        XCTAssertEqual(coordinator.level, .normal)
        coordinator.stop()
    }

    func testWarningShedsBackgroundBeforeCriticalReleasesModel() async {
        var events: [String] = []
        let released = expectation(description: "Resident model released")
        let coordinator = MemoryPressureCoordinator(
            backgroundPause: { events.append("background:\($0)") },
            completionPause: { events.append("completion:\($0)") },
            releaseModel: { events.append("release"); released.fulfill() })
        coordinator.handle(.warning)
        XCTAssertEqual(events, ["background:true"])
        coordinator.handle(.critical)
        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(Array(events.prefix(4)), ["background:true", "background:true", "completion:true", "release"])
        XCTAssertEqual(coordinator.level, .critical)
        XCTAssertFalse(events.contains("completion:false"))
    }

    func testNormalCannotUnblockCompletionUntilReleaseFinishes() async {
        var paused = false, backgroundPaused = false, releaseCount = 0
        let started = expectation(description: "Release suspended")
        let barrier = MemoryReleaseBarrier(started: started)
        let resumed = expectation(description: "Normal permits completion after drain")
        let coordinator = MemoryPressureCoordinator(backgroundPause: { backgroundPaused = $0 },
            completionPause: { paused = $0; if !$0 { resumed.fulfill() } },
            releaseModel: { releaseCount += 1; await barrier.wait() })
        coordinator.handle(.critical)
        await fulfillment(of: [started], timeout: 1)
        coordinator.handle(.critical)
        coordinator.handle(.normal)
        XCTAssertTrue(paused)
        XCTAssertTrue(backgroundPaused, "Normal cannot admit background loads during release")
        XCTAssertEqual(releaseCount, 1)
        await barrier.release()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertFalse(paused)
        XCTAssertFalse(backgroundPaused)
        XCTAssertEqual(releaseCount, 1)
    }

    func testEscalationDuringReleaseCannotBeUnblockedByOldFinalizer() async {
        var paused = false, releases = 0
        let started = expectation(description: "Critical release suspended")
        let barrier = MemoryReleaseBarrier(started: started)
        let finished = expectation(description: "Release operation returned")
        let coordinator = MemoryPressureCoordinator(backgroundPause: { _ in },
            completionPause: { paused = $0 },
            releaseModel: { releases += 1; await barrier.wait(); finished.fulfill() })
        coordinator.handle(.critical)
        await fulfillment(of: [started], timeout: 1)
        coordinator.handle(.normal)
        coordinator.handle(.critical)
        await barrier.release()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertTrue(paused)
        XCTAssertEqual(releases, 1)
        coordinator.handle(.normal)
        XCTAssertFalse(paused)
    }

    func testFailedReleaseRemainsBlockedUntilPressureRecovers() async {
        struct Failure: Error {}
        var paused = false
        let failed = expectation(description: "Release error surfaced")
        let coordinator = MemoryPressureCoordinator(backgroundPause: { _ in },
            completionPause: { paused = $0 }, releaseModel: { throw Failure() },
            releaseFailed: { _ in failed.fulfill() })
        coordinator.handle(.critical)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(paused)
        coordinator.handle(.normal)
        XCTAssertFalse(paused)
    }
}

private actor MemoryReleaseBarrier {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; started.fulfill()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class TestMemoryPressureSource: MemoryPressureEventSource {
    var handler: (@Sendable (MemoryPressureLevel) -> Void)?
    var stopCount = 0
    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) { self.handler = handler }
    func stop() { stopCount += 1; handler = nil }
}
