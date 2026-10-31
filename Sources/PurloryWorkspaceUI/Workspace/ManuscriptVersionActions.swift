import AppKit

@MainActor enum ManuscriptVersionActions {
    @discardableResult static func capture(session: ProjectSession, requests: ProjectEditorRequests,
        sceneAt: Int? = nil, label: String = "") async throws -> ManuscriptVersion {
        guard session.isEditorEditable, let source = session.selectedDocumentSnapshot,
              requests.editor(for: source.identity.key)?.hasMarkedText() != true else { throw ProjectSessionError.staleRuntime }
        if let editor = requests.editor(for: source.identity.key),
           !editor.serialize().utf16.elementsEqual(source.body.utf16) { throw ProjectSessionError.staleRuntime }
        let version = try ManuscriptVersion.capture(source, sceneAt: sceneAt, label: label)
        try session.updateUserData(JSONEncoder().encode(version), for: version.userDataKey, identity: source.identity)
        try await session.saveNow()
        return version
    }
    static func restore(_ comparison: ManuscriptComparison, change: Int? = nil,
        session: ProjectSession, requests: ProjectEditorRequests, undoManager: UndoManager? = nil) throws {
        guard session.runtimeIdentity == comparison.identity,
              (undoManager ?? requests.editor(for: comparison.identity.key)?.undoManager) != nil
        else { throw ProjectSessionError.staleRuntime }
        try WorkspaceDocumentTransaction.perform([.init(key: comparison.identity.key,
            expectedBody: comparison.expectedBody, body: comparison.restoredBody(change: change))],
            in: session, requests: requests, undoManager: undoManager, actionName: "원고 기록 복원")
    }
}
