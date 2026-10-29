import Foundation

public enum MemoryPressureLevel: Sendable, Equatable {
    case normal, warning, critical
}

@MainActor
public protocol MemoryPressureEventSource: AnyObject {
    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void)
    func stop()
}

@MainActor
public final class SystemMemoryPressureSource: MemoryPressureEventSource {
    private var source: (any DispatchSourceMemoryPressure)?
    public init() {}
    public func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        stop()
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [weak pressure] in
            guard let flags = pressure?.data else { return }
            handler(flags.contains(.critical) ? .critical : flags.contains(.warning) ? .warning : .normal)
        }
        source = pressure
        pressure.resume()
    }
    public func stop() { source?.cancel(); source = nil }
}

/// Device pressure is independent of project ownership. Foreground admission stays
/// closed until a critical release drains, even if normal pressure arrives sooner.
@MainActor
public final class MemoryPressureCoordinator {
    public private(set) var level: MemoryPressureLevel = .normal
    private let backgroundPause: (Bool) -> Void
    private let completionPause: (Bool) -> Void
    private let releaseModel: () async throws -> Void
    private let releaseFailed: (Error) -> Void
    private let pressureDidChange: (MemoryPressureLevel) -> Void
    private var releaseTask: Task<Void, Never>?
    private var completionIsPaused = false
    private var source: (any MemoryPressureEventSource)?
    private var eventGeneration = 0
    private var active = true

    public init(backgroundPause: @escaping (Bool) -> Void,
                completionPause: @escaping (Bool) -> Void,
                releaseModel: @escaping () async throws -> Void,
                releaseFailed: @escaping (Error) -> Void = { _ in },
                pressureDidChange: @escaping (MemoryPressureLevel) -> Void = { _ in }) {
        self.backgroundPause = backgroundPause; self.completionPause = completionPause
        self.releaseModel = releaseModel; self.releaseFailed = releaseFailed; self.pressureDidChange = pressureDidChange
    }

    public func start(source: any MemoryPressureEventSource = SystemMemoryPressureSource()) {
        self.source?.stop()
        eventGeneration += 1
        let generation = eventGeneration
        active = true
        self.source = source
        source.start { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.eventGeneration == generation, self.active else { return }
                self.handle(level)
            }
        }
    }

    public func stop() {
        active = false
        eventGeneration += 1
        source?.stop(); source = nil
        // Allow an admitted unload to drain. Stopped finalizers cannot reopen work.
    }

    /// Termination may stop event delivery, but must still drain an admitted release.
    public func waitForRelease() async { await releaseTask?.value }

    public func handle(_ next: MemoryPressureLevel) {
        guard active, next != level else { return }
        level = next
        pressureDidChange(next)
        backgroundPause(next != .normal || releaseTask != nil)
        if next == .critical {
            setCompletionPaused(true)
            guard releaseTask == nil else { return }
            releaseTask = Task { [weak self] in
                guard let self else { return }
                do { try await self.releaseModel() }
                catch { if self.active { self.releaseFailed(error) } }
                self.releaseTask = nil
                guard self.active else { return }
                if self.level == .normal { self.backgroundPause(false) }
                self.setCompletionPaused(self.level == .critical)
            }
        } else {
            setCompletionPaused(releaseTask != nil)
        }
    }

    private func setCompletionPaused(_ paused: Bool) {
        guard completionIsPaused != paused else { return }
        completionIsPaused = paused
        completionPause(paused)
    }
}
