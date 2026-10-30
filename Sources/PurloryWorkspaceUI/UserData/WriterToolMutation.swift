import Foundation

/// A field may send several callbacks before SwiftUI replaces its binding. Advance only
/// after this field's accepted write; external edits and A/B/A transitions remain stale.
@MainActor
final class WriterToolMutation {
    private var identity: ProjectRuntimeIdentity
    init(identity: ProjectRuntimeIdentity) { self.identity = identity }
    func perform(_ edit: ProjectWriterEdit, in session: ProjectSession) throws {
        try ProjectWriterEditing.perform(edit, in: session, identity: identity)
        if let next = session.runtimeIdentity { identity = next }
    }
}
