import Foundation

package protocol WritingDiagnosticsChunkProvider: Sendable {
    func analyzeChunks(_ request: WritingDiagnosticsRequest,
                       emit: @escaping @Sendable (KoreanDiagnosticsChunk) async throws -> Void) async throws
}
extension KoreanDiagnosticsProvider: WritingDiagnosticsChunkProvider { }

package struct WritingDiagnosticsReportEvent: Sendable {
    package enum Kind: Sendable {
        case progress(completed: Int, total: Int)
        case findings([WritingDiagnosticsFinding])
        case finished(WritingDiagnosticsCoverage)
        case cancelled
        case failed(WritingDiagnosticsAvailability)
    }
    package let runtime: ProjectRuntimeIdentity
    package let profileRevision: UInt64
    package let kind: Kind
}

/// A single-consumer report. Dropping its iterator cancels work even if the report value survives.
package struct WritingDiagnosticsReport: AsyncSequence, Sendable {
    package typealias Element = WritingDiagnosticsReportEvent
    package let storage: WritingDiagnosticsReportStorage
    package struct AsyncIterator: AsyncIteratorProtocol {
        private let consumer: WritingReportConsumer
        fileprivate init(_ storage: WritingDiagnosticsReportStorage) { consumer = WritingReportConsumer(storage) }
        package mutating func next() async -> Element? { await consumer.next() }
    }
    package func makeAsyncIterator() -> AsyncIterator { AsyncIterator(storage) }
    package func cancel() { storage.cancel() }
    package var bufferedEventCount: Int { get async { await storage.channel.bufferedCount } }
    package func waitForBufferedEvent() async { await storage.channel.waitForBufferedEvent() }
    package func waitForCompletion() async { await storage.waitForCompletion() }
}

private final class WritingReportConsumer: Sendable {
    package let storage: WritingDiagnosticsReportStorage
    package init(_ storage: WritingDiagnosticsReportStorage) { self.storage = storage }
    deinit { storage.cancel() }
    package func next() async -> WritingDiagnosticsReportEvent? {
        if Task.isCancelled { storage.cancel(); return nil }
        let event = await withTaskCancellationHandler { await storage.channel.next() } onCancel: { storage.cancel() }
        return Task.isCancelled ? nil : event
    }
}

/// No producer closure captures this storage strongly; abandoned reports cannot form a task cycle.
package final class WritingDiagnosticsReportStorage: @unchecked Sendable {
    package let channel: WritingReportChannel
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    package init(runtime: ProjectRuntimeIdentity, profileRevision: UInt64) {
        channel = WritingReportChannel(runtime: runtime, profileRevision: profileRevision)
    }
    deinit { cancel() }
    package func start(_ task: Task<Void, Never>) {
        let stop = lock.withLock { self.task = task; return cancelled }
        if stop { task.cancel() }
    }
    package func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
        let channel = channel
        Task { await channel.cancel() }
    }
    package func waitForCompletion() async {
        let current = lock.withLock { task }
        await current?.value
    }
}

/// One buffered event, one producer, one consumer. Cancellation wakes every suspended operation.
package actor WritingReportChannel {
    private let runtime: ProjectRuntimeIdentity
    private let profileRevision: UInt64
    private var buffered: WritingDiagnosticsReportEvent?
    private var ended = false
    private var cancelled = false
    private var receiver: CheckedContinuation<WritingDiagnosticsReportEvent?, Never>?
    private var capacity: [CheckedContinuation<Void, Error>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    package var bufferedCount: Int { buffered == nil ? 0 : 1 }
    package init(runtime: ProjectRuntimeIdentity, profileRevision: UInt64) { self.runtime = runtime; self.profileRevision = profileRevision }
    package func waitForCapacity() async throws {
        try Task.checkCancellation()
        guard !ended, !cancelled else { throw CancellationError() }
        if buffered == nil { return }
        try await withCheckedThrowingContinuation { capacity.append($0) }
        try Task.checkCancellation()
        guard !ended, !cancelled else { throw CancellationError() }
    }
    package func send(_ kind: WritingDiagnosticsReportEvent.Kind) async throws {
        try await waitForCapacity()
        let event = WritingDiagnosticsReportEvent(runtime: runtime, profileRevision: profileRevision, kind: kind)
        if let receiver { self.receiver = nil; receiver.resume(returning: event) }
        else { buffered = event }
        notifyObservers()
    }
    package func next() async -> WritingDiagnosticsReportEvent? {
        if let buffered {
            self.buffered = nil; wakeCapacity()
            return buffered
        }
        if ended { return nil }
        // Reports have one consumer; a second simultaneous receiver cannot steal its stream.
        guard receiver == nil else { return nil }
        return await withCheckedContinuation { receiver = $0 }
    }
    package func finish() {
        ended = true
        if buffered == nil { receiver?.resume(returning: nil); receiver = nil }
        wakeCapacity(); notifyObservers()
    }
    package func cancel() {
        guard !ended else { return }
        cancelled = true; ended = true
        let event = WritingDiagnosticsReportEvent(runtime: runtime, profileRevision: profileRevision, kind: .cancelled)
        if let receiver { self.receiver = nil; receiver.resume(returning: event) }
        else { buffered = event }
        wakeCapacity(); notifyObservers()
    }
    package func waitForBufferedEvent() async {
        if buffered != nil || ended { return }
        await withCheckedContinuation { observers.append($0) }
    }
    private func wakeCapacity() {
        let current = capacity; capacity.removeAll()
        for waiter in current {
            if ended || cancelled { waiter.resume(throwing: CancellationError()) } else { waiter.resume() }
        }
    }
    private func notifyObservers() {
        if buffered != nil || ended { let current = observers; observers.removeAll(); current.forEach { $0.resume() } }
    }
}
