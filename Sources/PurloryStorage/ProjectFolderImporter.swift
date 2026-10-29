import Darwin
import Foundation

extension ProjectStore {
    /// Copy into an exclusively owned inactive directory; activation belongs to ProjectSession.
    public func prepareProjectImport(from sourceDirectory: URL) throws -> WritingProjectID {
        try withStoreLock {
            try ProjectPaths.rejectSymlink(sourceDirectory)
            let source = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
            guard let uuid = UUID(uuidString: source.lastPathComponent) else {
                throw ProjectStoreError.invalidManifest
            }
            let id = WritingProjectID(rawValue: uuid)
            let sourceManifest = try ProjectPaths.checked("project.json", under: source)
            guard try FileManager.default.attributesOfItem(atPath: sourceManifest.path)[.type] as? FileAttributeType == .typeRegular else {
                throw ProjectStoreError.unsafePath(sourceManifest.path)
            }
            let manifest = try JSONDecoder().decode(ProjectManifest.self,
                from: files.read(sourceManifest))
            guard manifest.id == id else { throw ProjectStoreError.invalidManifest }
            guard ProjectManifest.supportsSchema(manifest.schemaVersion) else {
                throw ProjectStoreError.unsupportedSchema(manifest.schemaVersion)
            }
            let target = try rootURL(id.rawValue.uuidString)
            guard !files.fileExists(at: target) else { throw ProjectStoreError.projectAlreadyExists }
            let inventory = try importInventory(under: source)
            try Task.checkCancellation()
            // mkdir, unlike createDirectory, cannot silently adopt someone else's existing folder.
            guard mkdir(target.path, mode_t(0o700)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                for path in inventory.keys.sorted() {
                    try Task.checkCancellation()
                    let destination = try ProjectPaths.checked(path, under: target)
                    if inventory[path] == "" {
                        try files.createDirectory(at: destination)
                    } else {
                        let bytes = try files.read(ProjectPaths.checked(path, under: source))
                        guard ProjectDigest.hash(bytes) == inventory[path] else {
                            throw ProjectStoreError.damagedFile(path)
                        }
                        try files.writeAtomically(bytes, to: destination)
                    }
                }
                guard try importInventory(under: target) == inventory else {
                    throw ProjectStoreError.damagedFile("imported project")
                }
                _ = try loadUnlocked(id: id)
                guard try importInventory(under: source) == inventory else {
                    throw ProjectStoreError.damagedFile("source changed during import")
                }
                try Task.checkCancellation()
                return id
            } catch {
                // This path did not exist before our exclusive mkdir; never remove the source or a collision.
                try FileManager.default.removeItem(at: target)
                throw error
            }
        }
    }

    private func importInventory(under directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        var pending = [""]
        while let parent = pending.popLast() {
            try Task.checkCancellation()
            let folder = parent.isEmpty ? directory : try ProjectPaths.checked(parent, under: directory)
            for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
                try Task.checkCancellation()
                let path = parent.isEmpty ? child.lastPathComponent : parent + "/" + child.lastPathComponent
                let url = try ProjectPaths.checked(path, under: directory)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                let hash: String
                if values.isDirectory == true {
                    hash = ""
                    pending.append(path)
                } else if values.isRegularFile == true {
                    hash = ProjectDigest.hash(try files.read(url))
                } else {
                    throw ProjectStoreError.unsafePath(path)
                }
                guard result.updateValue(hash, forKey: path) == nil else {
                    throw ProjectStoreError.unsafePath(path)
                }
            }
        }
        return result
    }
}
