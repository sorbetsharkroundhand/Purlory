import Foundation

public enum FirstRunState: Equatable, Sendable {
    case needsProject
    case ready(WritingProjectID)
}

/// The durable first-run source of truth is ProjectStore itself, not a second boolean flag.
///
/// If a verified active project exists, onboarding is complete. If there is no active
/// project, onboarding is shown. Corrupt/unreadable active-project state throws instead of
/// silently pretending this is a fresh install.
public enum FirstRunStateResolver {
    public static func resolve(using store: ProjectStore) async throws -> FirstRunState {
        guard let active = try await store.activeProject() else {
            return .needsProject
        }
        return .ready(active.id)
    }
}
