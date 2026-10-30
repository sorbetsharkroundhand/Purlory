import Foundation

/// Immutable manuscript input for readers that must never mutate the project session.
public struct ProjectDocumentSnapshot: Equatable, Sendable {
    public let identity: ProjectRuntimeIdentity
    public let title: String
    public let source: DocumentSource
    public var body: String { source.string }
    public let kind: WritingDocument.Kind
    public let mode: WritingMode
    public let userData: [String: Data]

    public init(
        identity: ProjectRuntimeIdentity, title: String, body: String,
        kind: WritingDocument.Kind, mode: WritingMode, userData: [String: Data] = [:]
    ) {
        self.init(identity: identity, title: title, source: DocumentSource(body), kind: kind, mode: mode, userData: userData)
    }

    public init(
        identity: ProjectRuntimeIdentity, title: String, source: DocumentSource,
        kind: WritingDocument.Kind, mode: WritingMode, userData: [String: Data] = [:]
    ) {
        self.identity = identity
        self.title = title
        self.source = source
        self.kind = kind
        self.mode = mode
        self.userData = userData
    }
}
