import Foundation

struct WorkspaceModeOption: Equatable, Identifiable {
    let mode: WorkspaceMode
    let label: String

    var id: WorkspaceMode { mode }
}

enum WorkspaceModePresentation {
    /// Expose implemented surfaces while retaining stored choices for remaining modes.
    static func options(for mode: WritingMode) -> [WorkspaceModeOption] {
        (mode == .general ? [WorkspaceMode.write, .outline] : [.write, .map])
            .map { WorkspaceModeOption(mode: $0, label: label(for: $0)) }
    }

    private static func label(for mode: WorkspaceMode) -> String {
        switch mode {
        case .write: "쓰기"
        case .outline: "개요"
        case .map: "지도"
        case .review: "검토"
        }
    }
}

@MainActor
enum WorkspaceModeSelection {
    static func select(
        _ mode: WorkspaceMode,
        session: ProjectSession,
        requestEditorFocus: () -> Void
    ) {
        session.selectWorkspaceMode(mode)
        requestEditorFocus()
    }
}
