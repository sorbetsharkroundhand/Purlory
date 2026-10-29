import Foundation

/// Shared identifier check for in-memory mutations and durable manifest paths.
package enum ProjectUserDataKey {
    package static func validate(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 128, key != ".", key != "..",
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            throw ProjectStoreError.unsafePath(key)
        }
    }
}
