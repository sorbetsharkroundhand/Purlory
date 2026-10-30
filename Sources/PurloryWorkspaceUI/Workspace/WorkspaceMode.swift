import Foundation

public enum WorkspaceMode: String, Codable, CaseIterable, Sendable {
    case write
    case outline
    case map
    case review
}
