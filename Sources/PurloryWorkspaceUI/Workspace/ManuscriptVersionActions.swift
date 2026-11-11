import AppKit
import Foundation

@MainActor enum ManuscriptVersionActions {
    private static var inFlightDocuments: Set<ProjectDocumentKey> = []

    private static func withDocumentLock<T>(
        _ key: ProjectDocumentKey,
        operation: () async throws -> T
    ) async throws -> T {
        guard inFlightDocuments.insert(key).inserted else {
            throw ProjectSessionError.transitionInProgress
        }
        defer { inFlightDocuments.remove(key) }
        return try await operation()
    }

    @discardableResult static func capture(
        session: ProjectSession,
        requests: ProjectEditorRequests,
        sceneAt: Int? = nil,
        label: String = "",
        branchName: String? = nil,
        additionalParentID: UUID? = nil
    ) async throws -> ManuscriptVersion {
        guard session.isEditorEditable, let source = session.selectedDocumentSnapshot else {
            throw ProjectSessionError.staleRuntime
        }
        return try await withDocumentLock(source.identity.key) {
            try await captureUnlocked(
                session: session,
                requests: requests,
                sceneAt: sceneAt,
                label: label,
                branchName: branchName,
                additionalParentID: additionalParentID
            )
        }
    }

    @discardableResult private static func captureUnlocked(
        session: ProjectSession,
        requests: ProjectEditorRequests,
        sceneAt: Int? = nil,
        label: String = "",
        branchName: String? = nil,
        additionalParentID: UUID? = nil
    ) async throws -> ManuscriptVersion {
        guard session.isEditorEditable, let source = session.selectedDocumentSnapshot,
              requests.editor(for: source.identity.key)?.hasMarkedText() != true else { throw ProjectSessionError.staleRuntime }
        guard source.kind == .manuscript else { throw ManuscriptVersionError.unsupportedDocumentKind }
        if let editor = requests.editor(for: source.identity.key),
           !editor.serialize().utf16.elementsEqual(source.body.utf16) { throw ProjectSessionError.staleRuntime }

        let expectedIdentity = source.identity
        let expectedEpoch = session.activationEpoch
        var branchState = try ManuscriptBranchState.loadValid(in: source.userData, documentID: source.identity.key.documentID)
        let targetBranch = (branchName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? branchState.activeBranch
        let existingVersions = try ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID)
        var parentIDs: [UUID] = []
        if let head = branchState.resolveDocumentHead(for: targetBranch, in: existingVersions) {
            parentIDs.append(head.id)
        }
        if let additionalParentID, !parentIDs.contains(additionalParentID) {
            parentIDs.append(additionalParentID)
        }
        let parentSHAs = parentIDs.compactMap { id in existingVersions.first(where: { $0.id == id })?.gitCommitSHA }

        var version = try ManuscriptVersion.capture(
            source,
            sceneAt: sceneAt,
            label: label,
            parentIDs: parentIDs,
            branchName: targetBranch
        )
        try await session.saveNow()
        guard session.activationEpoch == expectedEpoch,
              let postSave = session.selectedDocumentSnapshot,
              postSave.identity == expectedIdentity,
              postSave.body.utf16.elementsEqual(source.body.utf16)
        else { throw ProjectSessionError.staleRuntime }

        let gitCommit = try await session.store.commitManuscriptGitVersion(
            projectID: source.identity.key.projectID,
            documentID: source.identity.key.documentID,
            branch: version.branchName,
            message: version.label,
            text: version.scope == .document ? version.text : source.body,
            parentSHAs: parentSHAs,
            timestamp: version.createdAt
        )
        version.gitCommitSHA = gitCommit.sha

        guard session.activationEpoch == expectedEpoch,
              let refreshed = session.selectedDocumentSnapshot,
              refreshed.identity == expectedIdentity,
              refreshed.body.utf16.elementsEqual(source.body.utf16)
        else { throw ProjectSessionError.staleRuntime }

        branchState.recordCommit(version)
        let encodedVersion = try JSONEncoder().encode(version)
        let encodedBranchState = try JSONEncoder().encode(branchState)
        try session.updateProjectUserData([
            version.userDataKey: encodedVersion,
            ManuscriptBranchState.userDataKey(for: source.identity.key.documentID): encodedBranchState
        ], projectID: source.identity.key.projectID)
        try await session.saveNow()
        return version
    }

    static func restore(
        _ comparison: ManuscriptComparison,
        change: Int? = nil,
        session: ProjectSession,
        requests: ProjectEditorRequests,
        undoManager: UndoManager? = nil
    ) throws {
        guard !inFlightDocuments.contains(comparison.identity.key) else {
            throw ProjectSessionError.transitionInProgress
        }
        guard session.runtimeIdentity == comparison.identity,
              (undoManager ?? requests.editor(for: comparison.identity.key)?.undoManager) != nil
        else { throw ProjectSessionError.staleRuntime }
        try WorkspaceDocumentTransaction.perform([.init(
            key: comparison.identity.key,
            expectedBody: comparison.expectedBody,
            body: comparison.restoredBody(change: change)
        )], in: session, requests: requests, undoManager: undoManager, actionName: "원고 기록 복원")
    }

    @discardableResult static func createBranch(
        name: String,
        from baseVersion: ManuscriptVersion? = nil,
        session: ProjectSession,
        requests: ProjectEditorRequests,
        undoManager: UndoManager? = nil
    ) async throws -> ManuscriptVersion {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManuscriptVersionError.duplicateBranchName }
        guard session.isEditorEditable, let source = session.selectedDocumentSnapshot,
              source.kind == .manuscript,
              requests.editor(for: source.identity.key)?.hasMarkedText() != true else { throw ProjectSessionError.staleRuntime }

        return try await withDocumentLock(source.identity.key) {
            let branchState = try ManuscriptBranchState.loadValid(in: source.userData, documentID: source.identity.key.documentID)
            let existingVersions = try ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID)
            let allBranchNames = Set(branchState.branches.map(\.name)).union(existingVersions.map(\.branchName))
            guard !allBranchNames.contains(trimmed) else { throw ManuscriptVersionError.duplicateBranchName }

            let currentHead = branchState.resolveDocumentHead(for: branchState.activeBranch, in: existingVersions)
            let explicitBase = baseVersion?.scope == .document ? baseVersion : nil
            var resolvedBase: ManuscriptVersion? = explicitBase

            if let explicitBase {
                if currentHead == nil || !currentHead!.text.utf8.elementsEqual(source.body.utf8) {
                    _ = try await captureUnlocked(
                        session: session,
                        requests: requests,
                        label: "\(branchState.activeBranch) 자동 보관",
                        branchName: branchState.activeBranch
                    )
                }
                if let currentSource = session.selectedDocumentSnapshot,
                   currentSource.identity.key == source.identity.key,
                   !explicitBase.text.utf8.elementsEqual(currentSource.body.utf8),
                   (undoManager ?? requests.editor(for: currentSource.identity.key)?.undoManager) != nil {
                    try WorkspaceDocumentTransaction.perform([.init(
                        key: currentSource.identity.key,
                        expectedBody: currentSource.body,
                        body: explicitBase.text
                    )], in: session, requests: requests, undoManager: undoManager, actionName: "갈림길 나누기")
                }
            } else if let currentHead {
                if !currentHead.text.utf8.elementsEqual(source.body.utf8) {
                    resolvedBase = try await captureUnlocked(
                        session: session,
                        requests: requests,
                        label: "\(branchState.activeBranch) 자동 보관",
                        branchName: branchState.activeBranch
                    )
                } else {
                    resolvedBase = currentHead
                }
            } else {
                resolvedBase = try await captureUnlocked(
                    session: session,
                    requests: requests,
                    label: "첫 기록",
                    branchName: branchState.activeBranch
                )
            }

            return try await captureUnlocked(
                session: session,
                requests: requests,
                label: "\(trimmed) 시작",
                branchName: trimmed,
                additionalParentID: resolvedBase?.id
            )
        }
    }

    static func switchBranch(
        to targetBranch: String,
        session: ProjectSession,
        requests: ProjectEditorRequests,
        undoManager: UndoManager? = nil
    ) async throws {
        guard session.isEditorEditable, let source = session.selectedDocumentSnapshot,
              source.kind == .manuscript,
              requests.editor(for: source.identity.key)?.hasMarkedText() != true,
              (undoManager ?? requests.editor(for: source.identity.key)?.undoManager) != nil
        else { throw ProjectSessionError.staleRuntime }

        try await withDocumentLock(source.identity.key) {
            let expectedEpoch = session.activationEpoch
            let branchState = try ManuscriptBranchState.loadValid(in: source.userData, documentID: source.identity.key.documentID)
            let existingVersions = try ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID)
            guard var targetVersion = branchState.resolveDocumentHead(for: targetBranch, in: existingVersions) else {
                throw ManuscriptVersionError.unknownBranch
            }

            let currentHead = branchState.resolveDocumentHead(for: branchState.activeBranch, in: existingVersions)
            if branchState.activeBranch != targetBranch {
                if currentHead == nil || !currentHead!.text.utf8.elementsEqual(source.body.utf8) {
                    _ = try await captureUnlocked(
                        session: session,
                        requests: requests,
                        label: "\(branchState.activeBranch) 전환 전 자동 보관",
                        branchName: branchState.activeBranch
                    )
                }
            } else if let currentHead, !currentHead.text.utf8.elementsEqual(source.body.utf8) {
                targetVersion = try await captureUnlocked(
                    session: session,
                    requests: requests,
                    label: "\(branchState.activeBranch) 전환 전 자동 보관",
                    branchName: branchState.activeBranch
                )
            }

            guard session.activationEpoch == expectedEpoch,
                  let refreshed = session.selectedDocumentSnapshot,
                  refreshed.identity.key == source.identity.key
            else { throw ProjectSessionError.staleRuntime }

            let beforeBranchState = try ManuscriptBranchState.loadValid(
                in: refreshed.userData,
                documentID: refreshed.identity.key.documentID
            )
            var afterBranchState = beforeBranchState
            afterBranchState.activeBranch = targetBranch
            if afterBranchState.headVersionID(for: targetBranch) != targetVersion.id {
                afterBranchState.recordCommit(targetVersion)
            }

            try ManuscriptBranchSwitchTransaction.perform(
                key: refreshed.identity.key,
                expectedBody: refreshed.body,
                afterBody: targetVersion.text,
                beforeBranchState: beforeBranchState,
                afterBranchState: afterBranchState,
                in: session,
                requests: requests,
                undoManager: undoManager,
                actionName: "갈림길 전환"
            )
            try await session.saveNow()
        }
    }

    static func previewMerge(
        from sourceBranch: String,
        in source: ProjectDocumentSnapshot
    ) throws -> (merge: ManuscriptThreeWayMerge, sourceHead: ManuscriptVersion, base: ManuscriptVersion?) {
        let branchState = try ManuscriptBranchState.loadValid(in: source.userData, documentID: source.identity.key.documentID)
        let versions = try ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID)
        guard let sourceHead = branchState.resolveDocumentHead(for: sourceBranch, in: versions) else {
            throw ManuscriptVersionError.unknownBranch
        }
        let currentHead = branchState.resolveDocumentHead(for: branchState.activeBranch, in: versions)
        let base = currentHead.flatMap { ManuscriptVersion.lowestCommonAncestor(of: $0.id, and: sourceHead.id, in: versions) }
        let merge = ManuscriptThreeWayMerge.merge(base: base?.text, ours: source.body, theirs: sourceHead.text)
        return (merge, sourceHead, base)
    }

    @discardableResult static func applyMerge(
        from sourceBranch: String,
        resolutions: [Int: ManuscriptThreeWayMerge.Resolution] = [:],
        expectedIdentity: ProjectRuntimeIdentity? = nil,
        expectedSourceHeadID: UUID? = nil,
        session: ProjectSession,
        requests: ProjectEditorRequests,
        undoManager: UndoManager? = nil
    ) async throws -> ManuscriptVersion {
        guard session.isEditorEditable, let source = session.selectedDocumentSnapshot,
              source.kind == .manuscript,
              requests.editor(for: source.identity.key)?.hasMarkedText() != true,
              (undoManager ?? requests.editor(for: source.identity.key)?.undoManager) != nil
        else { throw ProjectSessionError.staleRuntime }
        if let expectedIdentity, source.identity != expectedIdentity {
            throw ProjectSessionError.staleRuntime
        }

        return try await withDocumentLock(source.identity.key) {
            let (merge, sourceHead, _) = try previewMerge(from: sourceBranch, in: source)
            if let expectedSourceHeadID, sourceHead.id != expectedSourceHeadID {
                throw ProjectSessionError.staleRuntime
            }
            let mergedBody = merge.resolvedText(using: resolutions)
            let branchState = try ManuscriptBranchState.loadValid(in: source.userData, documentID: source.identity.key.documentID)
            if !source.body.utf8.elementsEqual(mergedBody.utf8) {
                try WorkspaceDocumentTransaction.perform([.init(
                    key: source.identity.key,
                    expectedBody: source.body,
                    body: mergedBody
                )], in: session, requests: requests, undoManager: undoManager, actionName: "원고 합치기")
            }
            return try await captureUnlocked(
                session: session,
                requests: requests,
                label: "‘\(sourceBranch)’ 합침",
                branchName: branchState.activeBranch,
                additionalParentID: sourceHead.id
            )
        }
    }

    /// Captures a quick note into a project `.note` document without switching the active manuscript tab or losing editor focus.
    @discardableResult static func appendQuickNote(
        _ noteText: String,
        session: ProjectSession,
        requests: ProjectEditorRequests
    ) throws -> WritingDocumentID {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session.isEditorEditable, let project = session.activeProject else {
            throw ProjectSessionError.staleRuntime
        }
        let activeDocID = session.selectedDocumentID
        let contextPrefix = session.selectedDocument.map { "[\($0.title)] " } ?? ""
        let entryLine = "- \(contextPrefix)\(trimmed)"

        if let existingNote = project.documents.first(where: { $0.kind == .note && !project.trashedDocumentIDs.contains($0.id) }) {
            let separator = existingNote.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
            let updatedBody = existingNote.body + separator + entryLine + "\n"
            try session.applyDocumentEdits([ProjectDocumentEdit(
                key: ProjectDocumentKey(projectID: project.id, documentID: existingNote.id),
                expectedBody: existingNote.body,
                body: updatedBody
            )])
            requests.focusEditor()
            return existingNote.id
        } else {
            guard let createdID = session.createDocument(title: "빠른 메모", kind: .note) else {
                throw ProjectSessionError.staleRuntime
            }
            try session.applyDocumentEdits([ProjectDocumentEdit(
                key: ProjectDocumentKey(projectID: project.id, documentID: createdID),
                expectedBody: "",
                body: "# 빠른 메모\n\n\(entryLine)\n"
            )])
            if let activeDocID {
                session.selectDocument(activeDocID)
            }
            requests.focusEditor()
            return createdID
        }
    }

    /// Automatically captures a safety version snapshot before structural edits (such as moving a paragraph or scene)
    /// when the manuscript has uncommitted changes on its active branch.
    @discardableResult static func captureSafetySnapshotIfNeeded(
        for key: ProjectDocumentKey,
        label: String = "구조 변경 전 자동 보관",
        in session: ProjectSession
    ) -> ManuscriptVersion? {
        guard !inFlightDocuments.contains(key),
              session.phase == .ready, !session.isTransitioning,
              let project = session.activeProject, project.id == key.projectID,
              !project.trashedDocumentIDs.contains(key.documentID),
              let document = session.document(key.documentID),
              document.kind == .manuscript,
              !document.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        guard var branchState = try? ManuscriptBranchState.loadValid(in: project.userData, documentID: key.documentID),
              let existingVersions = try? ManuscriptVersion.list(in: project.userData, documentID: key.documentID)
        else { return nil }
        let activeHead = branchState.resolveDocumentHead(for: branchState.activeBranch, in: existingVersions)
        if let activeHead, activeHead.text.utf8.elementsEqual(document.body.utf8) {
            return nil
        }

        let parentIDs = activeHead.map { [$0.id] } ?? []
        let snapshot = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 0),
            title: document.title,
            source: document.source,
            kind: document.kind,
            mode: project.mode,
            userData: project.userData
        )
        guard let version = try? ManuscriptVersion.capture(
            snapshot,
            label: label,
            parentIDs: parentIDs,
            branchName: branchState.activeBranch
        ) else { return nil }

        branchState.recordCommit(version)
        guard let encodedVersion = try? JSONEncoder().encode(version),
              let encodedBranchState = try? JSONEncoder().encode(branchState)
        else { return nil }

        try? session.updateProjectUserData([
            version.userDataKey: encodedVersion,
            ManuscriptBranchState.userDataKey(for: key.documentID): encodedBranchState
        ], projectID: key.projectID)
        return version
    }
}

/// Atomic branch-switch command that reverses both the manuscript body and `ManuscriptBranchState` on Undo/Redo.
@MainActor private final class ManuscriptBranchSwitchTransaction {
    private weak var session: ProjectSession?
    private weak var requests: ProjectEditorRequests?
    private let epoch: UInt64
    private let key: ProjectDocumentKey
    private let beforeBody: String
    private let afterBody: String
    private let beforeBranchState: ManuscriptBranchState
    private let afterBranchState: ManuscriptBranchState
    private let actionName: String
    private var applied = true
    private final class ManagerReference {
        weak var value: UndoManager?
        init(_ value: UndoManager) { self.value = value }
    }
    private var managers: [ManagerReference] = []
    private struct Position { let selection: NSRange; let scroll: CGPoint }
    private var beforePosition: Position?
    private var afterPosition: Position?

    @discardableResult static func perform(
        key: ProjectDocumentKey,
        expectedBody: String,
        afterBody: String,
        beforeBranchState: ManuscriptBranchState,
        afterBranchState: ManuscriptBranchState,
        in session: ProjectSession,
        requests: ProjectEditorRequests,
        undoManager: UndoManager? = nil,
        actionName: String
    ) throws -> ManuscriptBranchSwitchTransaction {
        let transaction = try ManuscriptBranchSwitchTransaction(
            key: key,
            expectedBody: expectedBody,
            afterBody: afterBody,
            beforeBranchState: beforeBranchState,
            afterBranchState: afterBranchState,
            session: session,
            requests: requests,
            actionName: actionName
        )
        transaction.beforePosition = transaction.capturePosition()
        try transaction.apply(body: afterBody, expectedBody: expectedBody, branchState: afterBranchState)
        transaction.synchronize(position: transaction.beforePosition)
        transaction.afterPosition = transaction.capturePosition()

        var unique: Set<ObjectIdentifier> = []
        let candidates = [undoManager, requests.editor(for: key)?.undoManager]
        for manager in candidates.compactMap({ $0 }) where unique.insert(ObjectIdentifier(manager)).inserted {
            transaction.managers.append(ManagerReference(manager))
            transaction.register(in: manager)
        }
        return transaction
    }

    private init(
        key: ProjectDocumentKey,
        expectedBody: String,
        afterBody: String,
        beforeBranchState: ManuscriptBranchState,
        afterBranchState: ManuscriptBranchState,
        session: ProjectSession,
        requests: ProjectEditorRequests,
        actionName: String
    ) throws {
        guard key.projectID == session.activeProject?.id,
              let document = session.document(key.documentID),
              document.body.utf16.elementsEqual(expectedBody.utf16)
        else { throw ProjectSessionError.staleRuntime }
        guard requests.editor(for: key)?.hasMarkedText() != true else {
            throw ProjectSessionError.transitionInProgress
        }
        self.session = session
        self.requests = requests
        self.epoch = session.activationEpoch
        self.key = key
        self.beforeBody = document.body
        self.afterBody = afterBody
        self.beforeBranchState = beforeBranchState
        self.afterBranchState = afterBranchState
        self.actionName = actionName
    }

    private func apply(
        body: String,
        expectedBody: String,
        branchState: ManuscriptBranchState
    ) throws {
        guard let session else { throw ProjectSessionError.staleRuntime }
        if !expectedBody.utf16.elementsEqual(body.utf16) {
            try session.applyDocumentEdits([ProjectDocumentEdit(
                key: key,
                expectedBody: expectedBody,
                body: body
            )])
        } else {
            guard session.document(key.documentID)?.body.utf16.elementsEqual(expectedBody.utf16) == true else {
                throw ProjectSessionError.staleRuntime
            }
        }
        let encoded = try JSONEncoder().encode(branchState)
        try session.updateProjectUserData([
            ManuscriptBranchState.userDataKey(for: key.documentID): encoded
        ], projectID: key.projectID)
    }

    private func register(in manager: UndoManager) {
        let group = manager.groupingLevel == 0
        if group { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { [self, weak manager] _ in
            guard let manager else { return }
            reverse(trigger: manager)
        }
        manager.setActionName(actionName)
        if group { manager.endUndoGrouping() }
    }

    private func reverse(trigger: UndoManager) {
        guard let session, session.activationEpoch == epoch else { return }
        let expectedBody = applied ? afterBody : beforeBody
        let targetBody = applied ? beforeBody : afterBody
        let targetBranchState = applied ? beforeBranchState : afterBranchState
        do {
            if requests?.editor(for: key)?.hasMarkedText() == true {
                throw ProjectSessionError.transitionInProgress
            }
            try apply(body: targetBody, expectedBody: expectedBody, branchState: targetBranchState)
            applied.toggle()
            synchronize(position: applied ? afterPosition : beforePosition)
            for reference in managers {
                guard let peer = reference.value, peer !== trigger else { continue }
                peer.removeAllActions(withTarget: self)
                if applied { register(in: peer) }
            }
            register(in: trigger)
        } catch {
            session.reportError(error)
        }
    }

    private func capturePosition() -> Position? {
        guard let editor = requests?.editor(for: key) else { return nil }
        return Position(
            selection: editor.selectedRange(),
            scroll: editor.enclosingScrollView?.contentView.bounds.origin ?? .zero
        )
    }

    private func synchronize(position: Position?) {
        guard let editor = requests?.editor(for: key),
              let body = session?.document(key.documentID)?.body else { return }
        let manager = editor.undoManager
        let enabled = manager?.isUndoRegistrationEnabled == true
        if enabled { manager?.disableUndoRegistration() }
        if let coordinator = editor.delegate as? PurloryBlockEditor.Coordinator {
            coordinator.applyWorkspaceSource(body, to: editor)
        } else {
            editor.load(markdown: body)
        }
        if enabled { manager?.enableUndoRegistration() }
        if let position {
            editor.restoreSelection(to: position.selection)
            editor.enclosingScrollView?.contentView.scroll(to: position.scroll)
            editor.enclosingScrollView?.reflectScrolledClipView(editor.enclosingScrollView!.contentView)
        }
    }
}
