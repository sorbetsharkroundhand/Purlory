import Foundation

/// Experimental strategies; the existing strategy remains the release default.
public enum GhostContextMode: String, CaseIterable, Codable, Sendable {
    case raw = "A"
    case rawWithNameAnchor = "B"
    case current = "C"

    public var label: String {
        switch self {
        case .raw: "A · 원문만"
        case .rawWithNameAnchor: "B · 원문과 이전 이름 언급"
        case .current: "C · 현재 방식"
        }
    }
}
