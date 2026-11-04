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
        if !copying,
           requests.editor(for: source.key)?.hasMarkedText() != true,
           requests.editor(for: target.key)?.hasMarkedText() != true {
            _ = ManuscriptVersionActions.captureSafetySnapshotIfNeeded(
                for: source.key,
                label: "문단 이동 전 자동 보관",
                in: session
            )
            if !same {
                _ = ManuscriptVersionActions.captureSafetySnapshotIfNeeded(
                    for: target.key,
                    label: "문단 이동 전 자동 보관",
                    in: session
                )
            }
        }
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

    @MainActor static func moveSceneSection(
        source sourceHeading: DocumentOutlineProjection.Heading,
        target targetHeading: DocumentOutlineProjection.Heading,
        after: Bool,
        key: ProjectDocumentKey? = nil,
        in session: ProjectSession,
        requests: ProjectEditorRequests = ProjectEditorRequests(),
        undoManager: UndoManager? = nil
    ) throws {
        let fallbackKey = session.activeProject.flatMap { project in
            session.selectedDocumentID.map { ProjectDocumentKey(projectID: project.id, documentID: $0) }
        }
        guard let resolvedKey = key ?? session.runtimeIdentity?.key ?? fallbackKey,
              session.activeProject?.id == resolvedKey.projectID,
              let body = session.document(resolvedKey.documentID)?.body else {
            throw ProjectSessionError.staleRuntime
        }
        guard sourceHeading.id != targetHeading.id else { return }
        let sourceAnchor = WorkspaceParagraphAnchor(
            key: resolvedKey,
            body: body,
            range: NSRange(location: sourceHeading.sectionRange.lowerBound, length: sourceHeading.sectionRange.count)
        )
        let targetAnchor = WorkspaceParagraphAnchor(
            key: resolvedKey,
            body: body,
            range: NSRange(location: targetHeading.sectionRange.lowerBound, length: targetHeading.sectionRange.count)
        )
        guard sourceAnchor.valid, targetAnchor.valid, sourceAnchor.range.length > 0 else {
            throw ProjectSessionError.staleRuntime
        }
        if NSIntersectionRange(sourceAnchor.range, targetAnchor.range).length > 0 { return }

        let sourceNS = body as NSString
        let originalHadTrailingNewline = body.hasSuffix("\n")
        let chunk = sourceNS.substring(with: sourceAnchor.range)
        let removed = sourceNS.replacingCharacters(in: sourceAnchor.range, with: "")
        var insertion = after ? targetAnchor.range.upperBound : targetAnchor.range.location
        if insertion >= sourceAnchor.range.upperBound {
            insertion -= sourceAnchor.range.length
        }
        let targetNS = removed as NSString
        guard insertion >= 0, insertion <= targetNS.length else {
            throw ProjectSessionError.staleRuntime
        }
        var payload = chunk
        if insertion > 0, targetNS.character(at: insertion - 1) != 10, !payload.hasPrefix("\n") {
            payload = "\n" + payload
        }
        if insertion < targetNS.length, targetNS.character(at: insertion) != 10, !payload.hasSuffix("\n") {
            payload += "\n"
        }
        var targetBody = targetNS.replacingCharacters(in: NSRange(location: insertion, length: 0), with: payload)
        if !originalHadTrailingNewline, targetBody.hasSuffix("\n") {
            targetBody.removeLast()
        }
        guard !targetBody.utf16.elementsEqual(body.utf16) else { return }

        if requests.editor(for: resolvedKey)?.hasMarkedText() != true {
            _ = ManuscriptVersionActions.captureSafetySnapshotIfNeeded(
                for: resolvedKey,
                label: "장면 순서 변경 전 자동 보관",
                in: session
            )
        }
        let resolvedUndo = undoManager ?? requests.editor(for: resolvedKey)?.undoManager
        try WorkspaceDocumentTransaction.perform(
            [ProjectDocumentEdit(key: resolvedKey, expectedBody: body, body: targetBody)],
            in: session,
            requests: requests,
            undoManager: resolvedUndo,
            actionName: "장면 순서 이동"
        )
        if let editor = requests.editor(for: resolvedKey),
           let row = editor.writingProjectionCapture.nativeRows.row(
               containingSource: min(insertion, max(0, (targetBody as NSString).length - 1))
           ) {
            editor.restoreSelection(to: NSRange(location: row.nativeRange.location, length: 0))
            editor.scrollRangeToVisible(row.nativeRange)
            editor.workspaceInteraction?.flash(row.nativeRange)
            editor.window?.makeFirstResponder(editor)
        }
    }
}
