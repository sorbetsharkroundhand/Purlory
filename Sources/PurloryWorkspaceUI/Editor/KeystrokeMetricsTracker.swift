import Foundation

/// Rolling-window local keystroke latency tracker publishing p95/max diagnostics every `publishStride` samples.
struct KeystrokeMetricsTracker: Sendable {
    private let maxSamples: Int
    private let publishStride: Int
    private var handlerSamples: [Double] = []
    private var totalSamples: [Double] = []
    private var samplesSincePublication = 0

    init(maxSamples: Int = 120, publishStride: Int = 20) {
        self.maxSamples = maxSamples
        self.publishStride = publishStride
    }

    mutating func record(handlerMs: Double, totalMs: Double) -> CompletionController.KeystrokeStats? {
        handlerSamples.append(handlerMs)
        totalSamples.append(totalMs)
        if handlerSamples.count > maxSamples {
            handlerSamples.removeFirst(handlerSamples.count - maxSamples)
            totalSamples.removeFirst(totalSamples.count - maxSamples)
        }
        samplesSincePublication += 1
        guard samplesSincePublication == publishStride else { return nil }
        samplesSincePublication = 0
        return CompletionController.KeystrokeStats(
            handlerP95: Self.p95(handlerSamples),
            totalP95: Self.p95(totalSamples),
            totalMax: totalSamples.max() ?? 0,
            samples: totalSamples.count
        )
    }

    private static func p95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
}
