import Foundation

package struct WritingEditorCommit: Sendable {
    package let baseIdentity: ProjectRuntimeIdentity
    package let nativeRevision: UInt64
    package let patch: WritingProjectionPatch
    package let markedRange: WritingDiagnosticRange?
    package init(baseIdentity: ProjectRuntimeIdentity, nativeRevision: UInt64,
                 patch: WritingProjectionPatch, markedRange: WritingDiagnosticRange?) {
        self.baseIdentity = baseIdentity; self.nativeRevision = nativeRevision
        self.patch = patch; self.markedRange = markedRange
    }
}
