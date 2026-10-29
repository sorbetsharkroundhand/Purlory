import Foundation

/// Immutable manuscript input for readers that must never mutate the project session.
public struct ProjectDocumentSnapshot: Equatable, Sendable {
    public let identity: ProjectRuntimeIdentity
    public let title: String
    public let body: String
    public let kind: WritingDocument.Kind
    public let mode: WritingMode
    public let userData: [String: Data]

    public init(
        identity: ProjectRuntimeIdentity, title: String, body: String,
        kind: WritingDocument.Kind, mode: WritingMode, userData: [String: Data] = [:]
    ) {
        self.identity = identity
        self.title = title
        self.body = body
        self.kind = kind
        self.mode = mode
        self.userData = userData
    }
}
