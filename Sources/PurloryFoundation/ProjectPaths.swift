import Foundation

package enum ProjectPaths {
    package static func validateRelative(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
            path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw ProjectStoreError.unsafePath(path) }
    }

    package static func checked(_ relative: String, under root: URL) throws -> URL {
        try validateRelative(relative)
        try rejectSymlink(root)
        var url = root
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component))
            try rejectSymlink(url)
        }
        return url
    }

    package static func rejectSymlink(_ url: URL) throws {
        // fileExists는 끊어진 링크를 놓치므로 lstat 기반 속성을 직접 확인한다.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ProjectStoreError.unsafePath(url.path)
        }
    }
}
