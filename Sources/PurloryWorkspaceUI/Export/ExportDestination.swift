import Darwin
import Foundation

/// Export paths are checked before any output and again at the atomic commit boundary.
enum ExportDestination {
    static func validatedFile(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ProjectStoreError.unsafePath(url.path) }
        try ProjectPaths.validateRelative(String(url.path.dropFirst()))
        var components = url.path.split(separator: "/").map(String.init)

        // macOS exposes its temporary directories through these root-owned system aliases.
        // Canonicalize only these exact links, never arbitrary user-selected symlinks.
        if let first = components.first, first == "var" || first == "tmp" {
            let alias = "/" + first
            let attributes = try FileManager.default.attributesOfItem(atPath: alias)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                try FileManager.default.destinationOfSymbolicLink(atPath: alias) == "private/\(first)" {
                components.insert("private", at: 0)
            }
        }

        var checked = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            checked.appendPathComponent(component)
            try ProjectPaths.rejectSymlink(checked)
            let isLeaf = index == components.count - 1
            if !isLeaf || FileManager.default.fileExists(atPath: checked.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: checked.path)
                let expected: FileAttributeType = isLeaf ? .typeRegular : .typeDirectory
                guard attributes[.type] as? FileAttributeType == expected else {
                    throw ProjectStoreError.unsafePath(checked.path)
                }
            }
        }
        return checked
    }

    static func write(_ data: Data, to url: URL) throws {
        let destination = try validatedFile(url)
        let staged = sibling(of: destination)
        defer { _ = unlink(staged.path) }
        try data.write(to: staged, options: .withoutOverwriting)
        try commit(stagedFile: staged, to: destination)
    }

    /// Copy a complete archive onto the destination volume before attempting replacement.
    static func replaceCompletedFile(_ source: URL, to url: URL) throws {
        let destination = try validatedFile(url)
        let source = try validatedFile(source)
        let staged = sibling(of: destination)
        defer { _ = unlink(staged.path) }
        try FileManager.default.copyItem(at: source, to: staged)
        try commit(stagedFile: staged, to: destination)
    }

    /// POSIX rename is atomic on one volume and never unlinks the old file on failure.
    static func commit(stagedFile: URL, to url: URL) throws {
        let destination = try validatedFile(url)
        let staged = try validatedFile(stagedFile)
        guard staged.deletingLastPathComponent() == destination.deletingLastPathComponent(), staged != destination else {
            throw ProjectStoreError.unsafePath(staged.path)
        }
        try Task.checkCancellation()
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func sibling(of destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".purlory-export-\(UUID().uuidString).tmp")
    }
}
