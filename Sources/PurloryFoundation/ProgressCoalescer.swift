import Foundation
import os

/// Coalesces frequent progress ticks so UI updates only after `minInterval` or on first/final tick.
package final class ProgressCoalescer: Sendable {
    private let lastAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    private let minInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    /// Final progress (`>= 1`) always emits so completion is never clipped.
    package init(
        minInterval: Duration = .milliseconds(250),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.minInterval = minInterval
        self.now = now
    }

    /// Returns true on the first tick, final tick (`>= 1`), or once `minInterval` has elapsed since the last emission.
    package func shouldEmit(_ fraction: Double) -> Bool {
        let current = now()
        return lastAt.withLock { last in
            let isFirst = last == nil
            let isFinal = fraction >= 1
            let enoughTime = last.map { current - $0 >= minInterval } ?? false
            if isFirst || isFinal || enoughTime {
                last = current
                return true
            }
            return false
        }
    }
}
