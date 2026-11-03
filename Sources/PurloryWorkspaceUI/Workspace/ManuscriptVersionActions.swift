import AppKit
import Foundation

@MainActor enum ManuscriptVersionActions {
    @discardableResult static func capture(
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

        var branchState = ManuscriptBranchState.load(in: source.userData, documentID: source.identity.key.documentID)
        let targetBranch = (branchName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? branchState.activeBranch
        let existingVersions = (try? ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID)) ?? []
        var parentIDs: [UUID] = []
        if let headID = branchState.headVersionID(for: targetBranch) ?? existingVersions.first(where: { $0.branchName == targetBranch })?.id {
            parentIDs.append(headID)
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

        guard let refreshed = session.selectedDocumentSnapshot,
              refreshed.identity.key == source.identity.key else { throw ProjectSessionError.staleRuntime }
        branchState.recordCommit(version)
        try session.updateUserData(JSONEncoder().encode(version), for: version.userDataKey, identity: refreshed.identity)
        if let latest = session.selectedDocumentSnapshot {
            try session.updateUserData(
                JSONEncoder().encode(branchState),
                for: ManuscriptBranchState.userDataKey(for: source.identity.key.documentID),
                identity: latest.identity
            )
        }
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

        let branchState = ManuscriptBranchState.load(in: source.userData, documentID: source.identity.key.documentID)
        let existingVersions = try ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID)
        let allBranchNames = Set(branchState.branches.map(\.name)).union(existingVersions.map(\.branchName))
        guard !allBranchNames.contains(trimmed) else { throw ManuscriptVersionError.duplicateBranchName }

        // Auto-save current branch state before branching if there are uncommitted changes.
        if let currentHeadID = branchState.headVersionID(for: branchState.activeBranch),
           let currentHead = existingVersions.first(where: { $0.id == currentHeadID }),
           !currentHead.text.utf8.elementsEqual(source.body.utf8) {
            _ = try await capture(session: session, requests: requests, label: "\(branchState.activeBranch) 자동 보관")
        } else if existingVersions.isEmpty {
            _ = try await capture(session: session, requests: requests, label: "첫 기록")
        }

        if let baseVersion, baseVersion.scope == .document,
           let currentSource = session.selectedDocumentSnapshot,
           !baseVersion.text.utf8.elementsEqual(currentSource.body.utf8),
           (undoManager ?? requests.editor(for: currentSource.identity.key)?.undoManager) != nil {
            try WorkspaceDocumentTransaction.perform([.init(
                key: currentSource.identity.key,
                expectedBody: currentSource.body,
                body: baseVersion.text
            )], in: session, requests: requests, undoManager: undoManager, actionName: "갈림길 나누기")
        }

        return try await capture(
            session: session,
            requests: requests,
            label: "\(trimmed) 시작",
            branchName: trimmed,
            additionalParentID: baseVersion?.id
        )
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

        var branchState = ManuscriptBranchState.load(in: source.userData, documentID: source.identity.key.documentID)
        let existingVersions = try ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID)
        guard let targetVersion = existingVersions.first(where: { $0.id == branchState.headVersionID(for: targetBranch) })
                ?? existingVersions.first(where: { $0.branchName == targetBranch })
        else { throw ManuscriptVersionError.unknownBranch }

        if branchState.activeBranch != targetBranch {
            let currentHead = existingVersions.first(where: { $0.id == branchState.headVersionID(for: branchState.activeBranch) })
                ?? existingVersions.first(where: { $0.branchName == branchState.activeBranch })
            if currentHead == nil || !currentHead!.text.utf8.elementsEqual(source.body.utf8) {
                _ = try await capture(
                    session: session,
                    requests: requests,
                    label: "\(branchState.activeBranch) 전환 전 자동 보관",
                    branchName: branchState.activeBranch
                )
            }
        }

        guard let refreshed = session.selectedDocumentSnapshot,
              refreshed.identity.key == source.identity.key else { throw ProjectSessionError.staleRuntime }
        branchState = ManuscriptBranchState.load(in: refreshed.userData, documentID: refreshed.identity.key.documentID)
        branchState.activeBranch = targetBranch
        try session.updateUserData(
            JSONEncoder().encode(branchState),
            for: ManuscriptBranchState.userDataKey(for: refreshed.identity.key.documentID),
            identity: refreshed.identity
        )
        if let latest = session.selectedDocumentSnapshot,
           !latest.body.utf8.elementsEqual(targetVersion.text.utf8) {
            try WorkspaceDocumentTransaction.perform([.init(
                key: latest.identity.key,
                expectedBody: latest.body,
                body: targetVersion.text
            )], in: session, requests: requests, undoManager: undoManager, actionName: "갈림길 전환")
        }
        try await session.saveNow()
    }

    static func previewMerge(
        from sourceBranch: String,
        in source: ProjectDocumentSnapshot
    ) throws -> (merge: ManuscriptThreeWayMerge, sourceHead: ManuscriptVersion, base: ManuscriptVersion?) {
        let branchState = ManuscriptBranchState.load(in: source.userData, documentID: source.identity.key.documentID)
        let versions = try ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID)
        guard let sourceHead = versions.first(where: { $0.id == branchState.headVersionID(for: sourceBranch) })
                ?? versions.first(where: { $0.branchName == sourceBranch })
        else { throw ManuscriptVersionError.unknownBranch }
        let currentHead = versions.first(where: { $0.id == branchState.headVersionID(for: branchState.activeBranch) })
            ?? versions.first(where: { $0.branchName == branchState.activeBranch })
        let base = currentHead.flatMap { ManuscriptVersion.lowestCommonAncestor(of: $0.id, and: sourceHead.id, in: versions) }
        let merge = ManuscriptThreeWayMerge.merge(base: base?.text, ours: source.body, theirs: sourceHead.text)
        return (merge, sourceHead, base)
    }

    @discardableResult static func applyMerge(
        from sourceBranch: String,
        resolutions: [Int: ManuscriptThreeWayMerge.Resolution] = [:],
        session: ProjectSession,
        requests: ProjectEditorRequests,
        undoManager: UndoManager? = nil
    ) async throws -> ManuscriptVersion {
        guard session.isEditorEditable, let source = session.selectedDocumentSnapshot,
              source.kind == .manuscript,
              requests.editor(for: source.identity.key)?.hasMarkedText() != true,
              (undoManager ?? requests.editor(for: source.identity.key)?.undoManager) != nil
        else { throw ProjectSessionError.staleRuntime }

        let (merge, sourceHead, _) = try previewMerge(from: sourceBranch, in: source)
        let mergedBody = merge.resolvedText(using: resolutions)
        let branchState = ManuscriptBranchState.load(in: source.userData, documentID: source.identity.key.documentID)
        if !source.body.utf8.elementsEqual(mergedBody.utf8) {
            try WorkspaceDocumentTransaction.perform([.init(
                key: source.identity.key,
                expectedBody: source.body,
                body: mergedBody
            )], in: session, requests: requests, undoManager: undoManager, actionName: "원고 합치기")
        }
        return try await capture(
            session: session,
            requests: requests,
            label: "‘\(sourceBranch)’ 합침",
            branchName: branchState.activeBranch,
            additionalParentID: sourceHead.id
        )
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
        guard session.phase == .ready, !session.isTransitioning,
              let project = session.activeProject, project.id == key.projectID,
              !project.trashedDocumentIDs.contains(key.documentID),
              let document = session.document(key.documentID),
              document.kind == .manuscript,
              !document.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var branchState = ManuscriptBranchState.load(in: project.userData, documentID: key.documentID)
        let existingVersions = (try? ManuscriptVersion.list(in: project.userData, documentID: key.documentID)) ?? []
        let activeHead = existingVersions.first(where: { $0.id == branchState.headVersionID(for: branchState.activeBranch) })
            ?? existingVersions.first(where: { $0.branchName == branchState.activeBranch })
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
