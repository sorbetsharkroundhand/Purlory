import Foundation

/// Confirmation precedes mutation; native presentation and automated choices share this flow.
@MainActor
final class ProjectRecoveryFlow {
    private let session: ProjectSession
    private(set) var isRunning = false
    init(session: ProjectSession) { self.session = session }

    @discardableResult
    func run(confirm: (ProjectBackupPreview) async throws -> Bool) async throws -> Bool {
        guard !isRunning else { throw ProjectSessionError.transitionInProgress }
        isRunning = true
        defer { isRunning = false }
        let preview = try await session.backupForRecovery()
        guard try await confirm(preview) else { return false }
        try await session.restoreBackup(preview)
        return true
    }
}
