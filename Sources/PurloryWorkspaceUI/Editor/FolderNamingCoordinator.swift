import AppKit
import Foundation
import PurloryInference
import PurloryStorage
import SwiftUI

/// Owns background auto-naming tasks for newly merged navigator folders and cancels them safely on teardown or removal.
@MainActor
final class FolderNamingCoordinator {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func requestFolderName(
        for folderID: UUID,
        in session: ProjectSession,
        engine: CompletionEngine,
        parameters: CompletionParameters,
        maxContextCharacters: Int,
        onInsertID: @escaping @MainActor (UUID) -> Void,
        onRemoveID: @escaping @MainActor (UUID) -> Void
    ) {
        guard tasks[folderID] == nil,
              let project = session.activeProject,
              let navigation = try? ProjectNavigation.read(project)
        else { return }
        let members = project.documents.filter {
            !project.trashedDocumentIDs.contains($0.id) && navigation.documentFolders[$0.id] == folderID
        }
        guard !members.isEmpty else { return }
        let content = String(members.enumerated().map { index, doc in
            "[문서 \(index + 1)] 제목: \(doc.title)\n\(doc.body.prefix(300))"
        }.joined(separator: "\n\n").prefix(maxContextCharacters))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let projectID = project.id
        let epoch = session.activationEpoch
        onInsertID(folderID)
        let task = Task { [engine, weak session, weak self] in
            let name = (try? await engine.generateFolderName(content: content, parameters: parameters)) ?? ""
            guard !Task.isCancelled else { return }
            self?.tasks[folderID] = nil
            onRemoveID(folderID)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let session,
                  session.activeProject?.id == projectID,
                  session.activationEpoch == epoch,
                  let currentProject = session.activeProject,
                  let currentNav = try? ProjectNavigation.read(currentProject),
                  let folder = currentNav.folders.first(where: { $0.id == folderID }),
                  folder.name == "새 폴더"
            else { return }
            let namingAnimation: Animation? =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil : .easeOut(duration: 0.18)
            withAnimation(namingAnimation) {
                try? session.applyNavigation(.renameFolder(folderID, trimmed), projectID: projectID, epoch: epoch)
            }
        }
        tasks[folderID] = task
    }

    @discardableResult
    func injectTestTask(
        folderID: UUID,
        onInsertID: (UUID) -> Void
    ) -> Task<Void, Never> {
        onInsertID(folderID)
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        tasks[folderID] = task
        return task
    }

    func cancel(folderID: UUID, onRemoveID: (UUID) -> Void) {
        tasks.removeValue(forKey: folderID)?.cancel()
        onRemoveID(folderID)
    }

    func cancelAll(onClearAll: () -> Void) {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        onClearAll()
    }
}
