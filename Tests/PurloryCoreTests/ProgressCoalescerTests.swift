@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 진행률 틱 coalescing 회귀 테스트 (이슈 #46) — 초당 수십 번의 진행 알림이
/// UI 재효율 없이 흡수되는지 고정한다. 시계를 주입해 실제 대기 없이
/// 경계 조건(첫 틱·최종 틱·간격 직전/직후)을 검증한다.
final class ProgressCoalescerTests: XCTestCase {

    /// 주입 가능한 가짜 시계 — `tick()`마다 지정 간격만큼 시간을 흐르게 한다.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = ContinuousClock.Instant.now

        var now: ContinuousClock.Instant {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func advance(_ duration: Duration) {
            lock.lock(); defer { lock.unlock() }
            current = current.advanced(by: duration)
        }
    }

    func test첫_틱은_항상_발행() {
        let clock = FakeClock()
        let coalescer = ProgressCoalescer(minInterval: .seconds(1), now: { clock.now })

        XCTAssertTrue(coalescer.shouldEmit(0.0))
    }

    func test간격_이내_틱은_차단() {
        let clock = FakeClock()
        let coalescer = ProgressCoalescer(minInterval: .milliseconds(250), now: { clock.now })

        XCTAssertTrue(coalescer.shouldEmit(0.1))
        clock.advance(.milliseconds(100))
        XCTAssertFalse(coalescer.shouldEmit(0.2))
        clock.advance(.milliseconds(100)) // 200ms — 아직 부족
        XCTAssertFalse(coalescer.shouldEmit(0.3))
    }

    func test간격_경과_후_발행() {
        let clock = FakeClock()
        let coalescer = ProgressCoalescer(minInterval: .milliseconds(250), now: { clock.now })

        XCTAssertTrue(coalescer.shouldEmit(0.1))
        clock.advance(.milliseconds(250))
        XCTAssertTrue(coalescer.shouldEmit(0.5))
    }

    func test최종값은_간격과_무관하게_항상_발행() {
        let clock = FakeClock()
        let coalescer = ProgressCoalescer(minInterval: .seconds(10), now: { clock.now })

        XCTAssertTrue(coalescer.shouldEmit(0.5))
        clock.advance(.milliseconds(1))
        // 마지막 상태가 잘리면 안 된다 — 100%는 즉시 통과.
        XCTAssertTrue(coalescer.shouldEmit(1.0))
    }

    func test차단된_틱은_기준을_미루지_않는다() {
        // 문서화된 핵심 불변식: 막힌 틱이 발행 기준을 밀면 연속 틱이
        // 간격을 영영 못 채운다. 차단 직후 정확히 minInterval 지점에서 통과해야 한다.
        let clock = FakeClock()
        let coalescer = ProgressCoalescer(minInterval: .milliseconds(250), now: { clock.now })

        XCTAssertTrue(coalescer.shouldEmit(0.0))   // 첫 틱 발행 — 기준 t=0
        clock.advance(.milliseconds(200))
        XCTAssertFalse(coalescer.shouldEmit(0.9))  // 차단 — 기준이 t=200으로 밀리면 안 됨
        clock.advance(.milliseconds(50))           // t=250
        // 버그가 있었다면 기준 200 + 50 = 간격 미달로 차단될 지점이다.
        XCTAssertTrue(coalescer.shouldEmit(0.95))
    }
}
