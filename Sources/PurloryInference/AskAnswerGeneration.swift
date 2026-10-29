import Foundation

package enum ReadyInstructionLimits {
    package static func promptFits(count: Int, budget: Int) -> Bool { count > 0 && budget > 0 && count <= budget }
}

/// A bounded ordered stream; overflow ends the producer before any later chunk can bridge the gap.
package struct AskAnswerGeneration: Sendable {
    package enum Failure: Error { case overflow }
    package let stream: AsyncThrowingStream<String, Error>
    private let task: Task<Void, Never>
    package init(bufferLimit: Int = 64, operation: @escaping @Sendable (@escaping @Sendable (String) throws -> Void) async throws -> Void) {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(max(1, bufferLimit)))
        self.stream = stream
        let worker = Task {
            do {
                try Task.checkCancellation()
                try await operation { chunk in
                    switch continuation.yield(chunk) {
                    case .enqueued: break
                    case .dropped: throw Failure.overflow
                    case .terminated: throw CancellationError()
                    @unknown default: throw Failure.overflow
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        task = worker
        continuation.onTermination = { _ in worker.cancel() }
    }
    package func cancelAndDrain() async { task.cancel(); await task.value }

}
