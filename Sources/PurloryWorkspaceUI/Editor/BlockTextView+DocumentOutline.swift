import AppKit

struct OutlineSourceTarget: Equatable, Sendable {
    let identity: ProjectRuntimeIdentity
    let revision: String
    let evidence: EvidenceAnchor
    let level: Int
    let sourceOffset: Int

    /// Explicit navigation only; no re-anchoring on a changed original.
    func matchesSource(_ source: String) -> Bool {
        let ns = source as NSString, count = evidence.quote.utf16.count
        guard (1...3).contains(level), evidence.documentID == identity.key.documentID,
              sourceOffset >= 0, sourceOffset <= ns.length, count > 0, count <= ns.length - sourceOffset,
              evidence.utf16Hint == sourceOffset, DocumentOutline.stableHash(source) == revision else { return false }
        return ns.substring(with: NSRange(location: sourceOffset, length: count))
            .utf16.elementsEqual(evidence.quote.utf16)
    }
}

@MainActor
extension BlockTextView {
    private func ownsOutlineMap(_ identity: ProjectRuntimeIdentity) -> Bool {
        writingDocumentIdentity == .project(identity.key) && writingRuntimeIdentityProvider?() == identity
            && !hasMarkedText() && writingProjectionCapture.compositionDepth == 0
            && writingProjectionCapture.mappedIdentity == identity
            && writingProjectionCapture.mappedRevision == writingNativeRevision
    }

    /// A row lookup, never a manuscript serialization or a scan through preceding text.
    func outlineSourcePosition(identity: ProjectRuntimeIdentity) -> Int? {
        guard ownsOutlineMap(identity) else { return nil }
        return writingProjectionCapture.nativeRows.row(containingNative: selectedRange().location)?.textStart
    }

    func applyOutlineHeading(_ target: OutlineSourceTarget) -> Bool {
        guard ownsOutlineMap(target.identity), target.matchesSource(serialize()),
              let row = writingProjectionCapture.nativeRows.row(containingSource: target.sourceOffset),
              row.textStart == target.sourceOffset, row.row.blockStyle.block == "h\(target.level)" else { return false }
        restoreSelection(to: NSRange(location: row.nativeRange.location, length: 0))
        return true
    }
}
