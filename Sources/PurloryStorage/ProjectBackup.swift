import Foundation

/// A verified local previous revision; the fingerprint binds restore to this preview.
public struct ProjectBackupPreview: Sendable {
    public let project: WritingProject
    public let assetCount: Int
    package let manifestFingerprint: String
}

extension ProjectStore {
    /// Resolve recovery ownership even when the selected project's current manifest is damaged.
    public func activeProjectID() throws -> WritingProjectID? {
        try withStoreLock {
            let url = try rootURL("active-project.json")
            guard files.fileExists(at: url) else { return nil }
            return try JSONDecoder().decode(WritingProjectID.self, from: files.read(url))
        }
    }

    public func previousBackup(id: WritingProjectID) throws -> ProjectBackupPreview {
        try withStoreLock {
            let manifest = try readManifest(id: id, name: "previous-project.json")
            return ProjectBackupPreview(project: try materialize(manifest), assetCount: manifest.assets.count,
                manifestFingerprint: try backupFingerprint(manifest))
        }
    }

    /// Create a verified independent copy. Source manifests/blobs and active marker are untouched.
    public func prepareBackupRestore(_ preview: ProjectBackupPreview, title: String? = nil) throws -> WritingProject {
        try withStoreLock {
            let manifest = try readManifest(id: preview.project.id, name: "previous-project.json")
            guard try backupFingerprint(manifest) == preview.manifestFingerprint else {
                throw ProjectStoreError.changedDuringSave
            }
            var recovered = try materialize(manifest)
            var assets: [String: Data] = [:]
            for asset in manifest.assets {
                try Task.checkCancellation()
                assets[asset.reference] = try verified(asset.file, in: manifest.id)
            }
            let archive = try manifest.legacySource.map { try verified($0, in: manifest.id) }
            recovered.id = WritingProjectID()
            if let title { recovered.title = title }
            guard !files.fileExists(at: try rootURL(recovered.id.rawValue.uuidString)) else {
                throw ProjectStoreError.projectAlreadyExists
            }
            try saveUnlocked(recovered, importedAssets: assets, source: archive)
            return try loadUnlocked(id: recovered.id)
        }
    }

    private func backupFingerprint(_ manifest: ProjectManifest) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ProjectDigest.hash(try encoder.encode(manifest))
    }
}
