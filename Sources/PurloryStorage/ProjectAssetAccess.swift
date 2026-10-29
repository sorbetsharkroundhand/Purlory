import Foundation

/// Verified bytes for exactly one project. Resolving a reference never touches disk.
public struct ProjectAssetCatalog: Sendable, Equatable {
    public let projectID: WritingProjectID
    private let assets: [String: Data]

    internal init(projectID: WritingProjectID, verifiedAssets: [String: Data]) {
        self.projectID = projectID
        self.assets = verifiedAssets
    }

    public func data(for reference: String) -> Data? {
        guard (try? ProjectPaths.validateRelative(reference)) != nil else { return nil }
        return assets[reference]
    }
}
