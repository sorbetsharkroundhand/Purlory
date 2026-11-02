import Foundation

/// A digest of one version of scene content. It is never a persistent scene identity.
public struct SceneContentVersion: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
