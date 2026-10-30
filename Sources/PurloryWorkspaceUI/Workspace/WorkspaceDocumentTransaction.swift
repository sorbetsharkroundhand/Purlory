import AppKit

/// One atomic source mutation, with coordinated native Undo in each affected open document.
@MainActor final class WorkspaceDocumentTransaction {
    private weak var session: ProjectSession?
    private weak var requests: ProjectEditorRequests?
    private let epoch: UInt64
    private let changes: [(key: ProjectDocumentKey, before: String, after: String)]
    private let actionName: String
    private var applied = true
    private final class ManagerReference { weak var value: UndoManager?; init(_ value: UndoManager) { self.value = value } }
    private var managers: [ManagerReference] = []
    private struct Position { let selection: NSRange; let scroll: CGPoint }
    private var beforePositions: [ProjectDocumentKey: Position] = [:]
    private var afterPositions: [ProjectDocumentKey: Position] = [:]

    @discardableResult static func perform(_ edits: [ProjectDocumentEdit], in session: ProjectSession,
        requests: ProjectEditorRequests, undoManager: UndoManager? = nil, actionName: String = "문서 편집"
    ) throws -> WorkspaceDocumentTransaction {
        let transaction = try WorkspaceDocumentTransaction(edits: edits, session: session, requests: requests, actionName: actionName)
        transaction.beforePositions = transaction.capturePositions()
        try session.applyDocumentEdits(edits)
        transaction.synchronize(positions: transaction.beforePositions)
        transaction.afterPositions = transaction.capturePositions()
        var unique: Set<ObjectIdentifier> = []
        let candidates = [undoManager] + edits.map { requests.editor(for: $0.key)?.undoManager }
        for manager in candidates.compactMap({ $0 }) where unique.insert(ObjectIdentifier(manager)).inserted {
            transaction.managers.append(ManagerReference(manager)); transaction.register(in: manager)
        }
        return transaction
    }

    private init(edits: [ProjectDocumentEdit], session: ProjectSession, requests: ProjectEditorRequests, actionName: String) throws {
        self.session = session; self.requests = requests; epoch = session.activationEpoch; self.actionName = actionName
        changes = try edits.map { edit in
            guard edit.key.projectID == session.activeProject?.id, let document = session.document(edit.key.documentID),
                  edit.expectedBody.map({ $0.utf16.elementsEqual(document.body.utf16) }) != false else { throw ProjectSessionError.staleRuntime }
            return (edit.key, document.body, edit.body)
        }
        for change in changes {
            guard requests.editor(for: change.key)?.hasMarkedText() != true else { throw ProjectSessionError.transitionInProgress }
        }
    }
    private func register(in manager: UndoManager) {
        let group = manager.groupingLevel == 0
        if group { manager.beginUndoGrouping() }
        // NSUndoManager does not retain its target. The action owns this command;
        // command -> manager references stay weak, so retiring the action releases it.
        manager.registerUndo(withTarget: self) { [self, weak manager] _ in
            guard let manager else { return }
            reverse(trigger: manager)
        }
        manager.setActionName(actionName)
        if group { manager.endUndoGrouping() }
    }
    private func reverse(trigger: UndoManager) {
        guard let session, session.activationEpoch == epoch else { return }
        let edits = changes.map { ProjectDocumentEdit(key: $0.key,
            expectedBody: applied ? $0.after : $0.before, body: applied ? $0.before : $0.after) }
        do {
            for change in changes where requests?.editor(for: change.key)?.hasMarkedText() == true {
                _ = change; throw ProjectSessionError.transitionInProgress
            }
            try session.applyDocumentEdits(edits)
            applied.toggle()
            synchronize(positions: applied ? afterPositions : beforePositions)
            for reference in managers {
                guard let peer = reference.value, peer !== trigger else { continue }
                peer.removeAllActions(withTarget: self)
                if applied { register(in: peer) }
            }
            register(in: trigger)
        } catch { session.reportError(error) }
    }
    private func capturePositions() -> [ProjectDocumentKey: Position] {
        var result: [ProjectDocumentKey: Position] = [:]
        for change in changes {
            if let editor = requests?.editor(for: change.key) {
                result[change.key] = Position(selection: editor.selectedRange(), scroll: editor.enclosingScrollView?.contentView.bounds.origin ?? .zero)
            }
        }
        return result
    }
    private func synchronize(positions: [ProjectDocumentKey: Position]) {
        for change in changes {
            guard let editor = requests?.editor(for: change.key), let body = session?.document(change.key.documentID)?.body else { continue }
            let manager = editor.undoManager, enabled = manager?.isUndoRegistrationEnabled == true
            if enabled { manager?.disableUndoRegistration() }
            if let coordinator = editor.delegate as? PurloryBlockEditor.Coordinator { coordinator.applyWorkspaceSource(body, to: editor) }
            else { editor.load(markdown: body) }
            if enabled { manager?.enableUndoRegistration() }
            if let position = positions[change.key] {
                editor.restoreSelection(to: position.selection)
                editor.enclosingScrollView?.contentView.scroll(to: position.scroll)
                editor.enclosingScrollView?.reflectScrolledClipView(editor.enclosingScrollView!.contentView)
            }
        }
    }
}
