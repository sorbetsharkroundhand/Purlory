import AppKit

/// Saves the explicit write owner before any irreversible shutdown and replies once per request.
@MainActor
public final class ProjectTerminationCoordinator {
    private let session: ProjectSession
    private let persistPositions: () -> Void
    private let shutdown: () -> Void
    private let drain: () async -> Void
    private var pendingTask: Task<Void, Never>?
    private var approved = false

    public init(
        session: ProjectSession,
        persistPositions: @escaping () -> Void,
        shutdown: @escaping () -> Void,
        drain: @escaping () async -> Void
    ) {
        self.session = session
        self.persistPositions = persistPositions
        self.shutdown = shutdown
        self.drain = drain
    }

    public func requestTermination(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard pendingTask == nil, !approved else { return .terminateLater }
        pendingTask = Task { @MainActor in
            let result = await prepareForTermination()
            approved = result == .terminateNow
            pendingTask = nil
            reply(approved)
        }
        return .terminateLater
    }

    public func prepareForTermination() async -> NSApplication.TerminateReply {
        do {
            try await session.flushForTermination()
        } catch {
            session.reportError(error)
            return .terminateCancel
        }
        persistPositions()
        shutdown()
        await drain()
        return .terminateNow
    }
}
