@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore

/// 모델 다운로드 수명주기 회귀 (이슈 #46).
///
/// 진행률 틱마다 태스크를 스폰·상태를 쓰던 옛 경로는 수 GB 다운로드 내내
/// 누적됐다. coalescing 판정과 열/저전력 게이트를 값 수준에서 고정한다.
final class DownloadLifecycleTests: XCTestCase {

    // MARK: - 진행률 coalescing

    /// 주입 가능한 시계 — 실제 대기 없이 경과를 만든다.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ContinuousClock.Instant = .now
        var current: ContinuousClock.Instant {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func advance(_ duration: Duration) {
            lock.lock(); defer { lock.unlock() }
            value = value + duration
        }
    }

    @MainActor
    func test첫틱은통과하고최소간격전의틱은막는다() {
        let clock = FakeClock()
        let coalescer = ProgressCoalescer(minInterval: .milliseconds(250)) { clock.current }

        XCTAssertTrue(coalescer.shouldEmit(0.0), "첫 틱은 항상 통과")

        clock.advance(.milliseconds(100))
        XCTAssertFalse(coalescer.shouldEmit(0.1), "간격 전 틱은 막혀야 한다")
        clock.advance(.milliseconds(100))
        XCTAssertFalse(coalescer.shouldEmit(0.2))

        clock.advance(.milliseconds(200))  // 누적 400ms ≥ 250ms
        XCTAssertTrue(coalescer.shouldEmit(0.3), "간격이 지나면 다시 통과")
    }

    @MainActor
    func test최종틱은간격과무관하게항상통과한다() {
        let clock = FakeClock()
        let coalescer = ProgressCoalescer(minInterval: .milliseconds(250)) { clock.current }
        _ = coalescer.shouldEmit(0.5)

        clock.advance(.milliseconds(10))
        XCTAssertTrue(coalescer.shouldEmit(1.0), "완료 신호가 잘리면 상태가 영원히 %에 멈춘다")
    }

    // MARK: - 열/저전력 게이트

    @MainActor
    func test심각한열상태에서는시작을보류한다() {
        XCTAssertNotNil(
            ModelDownloadManager.startBlockReason(thermal: .serious, lowPower: false))
        XCTAssertNotNil(
            ModelDownloadManager.startBlockReason(thermal: .critical, lowPower: false))
        XCTAssertNil(
            ModelDownloadManager.startBlockReason(thermal: .nominal, lowPower: false),
            "정상 조건에선 시작을 막지 않는다")
    }

    @MainActor
    func test저전력모드에서는시작을보류한다() {
        let reason = ModelDownloadManager.startBlockReason(
            thermal: .nominal, lowPower: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("저전력") ?? false, "이유를 사용자 언어로 알려야 재시도할 수 있다")
    }
}
