import Foundation

/// Legacy data is copied into the project runtime; startup never creates an EntryStore.
@MainActor
public final class ProjectStartupCoordinator {
    private let session: ProjectSession
    private let store: ProjectStore
    private let storageLocation: PurloryStorageLocation

    public init(session: ProjectSession, store: ProjectStore, storageLocation: PurloryStorageLocation = .standard) {
        self.session = session; self.store = store; self.storageLocation = storageLocation
    }

    public func bootstrap() async throws {
        var migration: LegacyMigrationResult?
        try await session.bootstrap(initialProject: {
            migration = try await self.store.prepareLocalLegacyProject(in: self.storageLocation.rootDirectory)
            return migration?.projectID
        })
        restoreSelection(migration)
    }

    public func openLegacyLibrary() async throws {
        var migration: LegacyMigrationResult?
        try await session.activateProject(preparing: {
            migration = try await self.store.prepareLocalLegacyProject(in: self.storageLocation.rootDirectory)
            guard let migration else { throw LegacyStartupError.noLegacyLibrary }
            return migration.projectID
        })
        restoreSelection(migration)
    }

    private func restoreSelection(_ migration: LegacyMigrationResult?) {
        if let migration, !migration.reusedExistingProject, let id = migration.selectedDocumentID {
            session.selectDocument(id)
        }
    }
}

enum LegacyStartupError: LocalizedError {
    case recoverySelectionRequired, noLegacyLibrary
    var errorDescription: String? {
        switch self {
        case .recoverySelectionRequired: "이전 원고의 복구 파일이 있습니다. ‘이전 원고 파일 선택…’에서 사용할 파일을 선택하세요. 원본은 보존됩니다."
        case .noLegacyLibrary: "이 저장 위치에 이전 원고가 없습니다. ‘프로젝트 가져오기…’ 또는 ‘이전 원고 파일 선택…’에서 원고를 선택하세요."
        }
    }
}
