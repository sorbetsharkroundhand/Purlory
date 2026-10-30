import Foundation

/// One prepared writer value. Body generations reuse it until opaque metadata changes.
package struct WriterDocumentReader {
    package init() {}
    private var key: ProjectDocumentKey?
    private var bytes: Data?
    private var result: Result<WriterDocumentData, Error>?

    package mutating func read(_ snapshot: ProjectDocumentSnapshot) throws -> WriterDocumentData {
        let nextKey = snapshot.identity.key
        let nextBytes = snapshot.userData[WriterDocumentData.key(for: nextKey.documentID)]
        if key == nextKey, bytes == nextBytes, let result { return try result.get() }
        let decoded = Result { try WriterDocumentData.decode(nextBytes, documentID: nextKey.documentID) }
        key = nextKey; bytes = nextBytes; result = decoded
        return try decoded.get()
    }
}
