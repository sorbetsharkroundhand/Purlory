import Foundation

/// 진행률 틱 coalescing (이슈 #46) — 허브 클라이언트·로더는 초당 수십 번
/// 진행을 알리지만, UI가 의미 있게 다시 그릴 주기는 그보다 훨씬 느리다.
/// 틱마다 MainActor 태스크를 스폰하거나 @Published를 쓰는 낭비를 줄인다.
///
/// 시계는 주입한다 — 테스트가 실제 대기 없이 경과를 만든다. 잠금으로 여러
/// 스레드의 틱에도 판정이 한 번만 나온다.
package final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAt: ContinuousClock.Instant?
    private var lastFraction: Double = -1
    private let minInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    /// 최종 값(1.0)은 항상 통과 — 마지막 상태가 잘리지 않게.
    package init(
        minInterval: Duration = .milliseconds(250),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.minInterval = minInterval
        self.now = now
    }

    /// 이 틱을 상태 반영할 만한가 — 첫 틱·최종 틱은 항상, 그 외엔 "마지막
    /// 발행"으로부터 최소 간격이 지났을 때만 참. 차단된 틱은 기준 시각을
    /// 미루지 않는다 — 그렇지 않으면 연속 틱이 간격을 영영 못 채운다.
    package func shouldEmit(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        let isFirst = lastAt == nil
        let isFinal = fraction >= 1
        let enoughTime = lastAt.map { current - $0 >= minInterval } ?? false

        if isFirst || isFinal || enoughTime {
            lastAt = current
            lastFraction = fraction
            return true
        }
        // 막힌 틱은 최신 비율만 캐시 — 발행 기준(lastAt)은 그대로 둔다.
        lastFraction = fraction
        return false
    }
}
