import Foundation

/// Only the last successful save is retained. Assets are represented by versions,
/// never duplicate byte buffers. Strict load/activation does not consult this cache.
struct ProjectSaveBaseline {
    let project: WritingProject
    let manifest: ProjectManifest
    let manifestBytes: Data
    let versions: [String: ProjectFileVersion]
}

extension ProjectManifest {
    var durableFiles: [ProjectFileRecord] {
        documents.map { ProjectFileRecord(relativePath: $0.relativePath, contentHash: $0.contentHash) }
            + assets.map(\.file) + Array(userData.values) + (legacySource.map { [$0] } ?? [])
    }
}

extension ProjectStore {
    /// Capture a version around the checksum read; never bless bytes with a later
    /// file's version if an external writer changed the file during verification.
    func readForSave(_ record: ProjectFileRecord, in id: WritingProjectID,
                     versions: inout [String: ProjectFileVersion]) throws -> Data {
        let url = try projectURL(id, record.relativePath)
        let before = try files.version(of: url)
        let data = try verified(record, in: id)
        let after = try files.version(of: projectURL(id, record.relativePath))
        guard before == after else { throw ProjectStoreError.changedDuringSave }
        versions[record.relativePath] = after
        return data
    }

    func verifyForSave(_ manifest: ProjectManifest,
                       versions: inout [String: ProjectFileVersion]) throws {
        for record in manifest.durableFiles {
            try Task.checkCancellation()
            let url = try projectURL(manifest.id, record.relativePath)
            if let known = versions[record.relativePath], try files.version(of: url) == known { continue }
            _ = try readForSave(record, in: manifest.id, versions: &versions)
        }
    }
}
