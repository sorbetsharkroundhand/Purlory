import Foundation

/// One app-owned monitor for the existing shared engine. Project storage and writer
/// decisions never participate in pressure shedding; only derived/model work pauses.
@MainActor
public final class MemoryPressureRuntime {
    private let coordinator: MemoryPressureCoordinator

    public init(completion: CompletionController, indexer: BackgroundIndexer,
                engine: CompletionEngine,
                source: any MemoryPressureEventSource = SystemMemoryPressureSource(),
                writingDiagnostics: WritingDiagnosticsRuntime? = nil) {
        coordinator = MemoryPressureCoordinator(
            backgroundPause: { [weak indexer, weak writingDiagnostics] paused in
                indexer?.setMemoryPressurePaused(paused)
                writingDiagnostics?.setSharedBackgroundPaused(paused)
            },
            completionPause: { [weak completion] in completion?.setMemoryPressurePaused($0) },
            releaseModel: {
                await writingDiagnostics?.waitForNativeRelease()
                try await engine.unload()
            },
            releaseFailed: { [weak completion] in completion?.noteMemoryReleaseFailure($0) },
            pressureDidChange: { [weak writingDiagnostics] in writingDiagnostics?.noteMemoryPressure($0) })
        coordinator.start(source: source)
    }

    public func stop() { coordinator.stop() }
    public func drain() async { await coordinator.waitForRelease() }
}
