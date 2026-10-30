import Foundation

/// Pure product routing. This layer deliberately imports no Story Intelligence/Fiction types.
public enum WorkspaceRouting {
    public static func availableModes(for mode: WritingMode) -> [WorkspaceMode] {
        switch mode {
        case .fiction:
            [.write, .map, .review]
        case .general:
            [.write, .outline, .review]
        }
    }

    public static func normalizedSelection(
        _ saved: WorkspaceMode?,
        for mode: WritingMode
    ) -> WorkspaceMode {
        guard let saved, availableModes(for: mode).contains(saved) else {
            return .write
        }
        return saved
    }
}
