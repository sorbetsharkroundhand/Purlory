import AppKit

struct WorkspaceParagraphAnchor {
    let key: ProjectDocumentKey
    let body: String
    let range: NSRange
    var valid: Bool {
        let ns = body as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= ns.length, range.length <= ns.length - range.location else { return false }
        if range.length > 0, ns.rangeOfComposedCharacterSequences(for: range) != range { return false }
        return true
    }
}

enum WorkspaceParagraphTransfer {
    @MainActor static func perform(source: WorkspaceParagraphAnchor, target: WorkspaceParagraphAnchor,
        after: Bool, copy: Bool, session: ProjectSession, requests: ProjectEditorRequests, undoManager: UndoManager? = nil
    ) throws {
        guard source.valid, target.valid, source.range.length > 0,
              source.key.projectID == target.key.projectID,
              session.activeProject?.id == source.key.projectID,
              session.document(source.key.documentID)?.body.utf16.elementsEqual(source.body.utf16) == true,
              session.document(target.key.documentID)?.body.utf16.elementsEqual(target.body.utf16) == true
        else { throw ProjectSessionError.staleRuntime }
        let same = source.key == target.key
        if same, NSIntersectionRange(source.range, target.range).length > 0 { return }
        let sourceNS = source.body as NSString
        let chunk = sourceNS.substring(with: source.range)
        let removed = sourceNS.replacingCharacters(in: source.range, with: "")
        let copying = copy || removed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var insertion = after ? target.range.upperBound : target.range.location
        var targetBody = target.body
        if same && !copying {
            targetBody = removed
            if insertion >= source.range.upperBound { insertion -= source.range.length }
        }
        let targetNS = targetBody as NSString
        guard insertion >= 0, insertion <= targetNS.length else { throw ProjectSessionError.staleRuntime }
        var payload = chunk
        if insertion > 0, targetNS.character(at: insertion - 1) != 10, !payload.hasPrefix("\n") { payload = "\n" + payload }
        if insertion < targetNS.length, targetNS.character(at: insertion) != 10, !payload.hasSuffix("\n") { payload += "\n" }
        targetBody = targetNS.replacingCharacters(in: NSRange(location: insertion, length: 0), with: payload)
        var edits = [ProjectDocumentEdit(key: target.key, expectedBody: target.body, body: targetBody)]
        if !same && !copying { edits.append(.init(key: source.key, expectedBody: source.body, body: removed)) }
        try WorkspaceDocumentTransaction.perform(edits, in: session, requests: requests, undoManager: undoManager,
            actionName: copying ? "문단 복제" : "문단 이동")
        requests.spatialWorkspace?.open(target.key.documentID)
        session.selectDocument(target.key.documentID)
        if let editor = requests.editor(for: target.key),
           let row = editor.writingProjectionCapture.nativeRows.row(containingSource: insertion) {
            editor.restoreSelection(to: NSRange(location: row.nativeRange.location, length: 0))
            editor.scrollRangeToVisible(row.nativeRange)
            editor.workspaceInteraction?.flash(row.nativeRange)
            editor.window?.makeFirstResponder(editor)
        }
    }
}
