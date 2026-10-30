import Foundation

/// A captured source body makes multi-document editing all-or-nothing and stale-safe.
struct ProjectDocumentEdit: Sendable {
    let key: ProjectDocumentKey
    let expectedBody: String?
    let body: String
}
