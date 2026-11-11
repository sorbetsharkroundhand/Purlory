import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryDocumentEngine
@testable import PurloryFoundation
@testable import PurloryStorage
@testable import PurloryWorkspaceUI

@MainActor final class ManuscriptVersionReviewRegressionTests: XCTestCase {
    // MARK: - F01: Scene versions must never become branch HEAD or overwrite full manuscript on switch

    func testF01SceneVersionDoesNotBecomeBranchHeadOrOverwriteFullManuscript() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(
            store: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            autosaveDelay: .seconds(3600)
        )
        var project = projectFixture()
        let docID = project.documents[0].id
        let fullBody = "# 1장 새벽\n첫 번째 장면 본문입니다.\n\n# 2장 밤\n두 번째 장면 본문입니다.\n"
        project.documents[0].body = fullBody
        try await session.saveAndActivate(project)

        let requests = ProjectEditorRequests()
        let editor = BlockTextView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.documentUndoManager = undo
        editor.load(markdown: fullBody)
        requests.register(editor, for: .init(projectID: project.id, documentID: docID))

        let docVersion = try await ManuscriptVersionActions.capture(
            session: session,
            requests: requests,
            label: "전체 초고"
        )
        XCTAssertEqual(docVersion.scope, .document)

        let sceneOffset = (fullBody as NSString).range(of: "# 2장 밤").location
        let sceneVersion = try await ManuscriptVersionActions.capture(
            session: session,
            requests: requests,
            sceneAt: sceneOffset,
            label: "2장 장면 보관"
        )
        XCTAssertEqual(sceneVersion.scope, .scene)
        XCTAssertEqual(sceneVersion.text, "# 2장 밤\n두 번째 장면 본문입니다.\n")

        let userData = try XCTUnwrap(session.activeProject?.userData)
        let branchState = try ManuscriptBranchState.loadValid(in: userData, documentID: docID)
        let versions = try ManuscriptVersion.list(in: userData, documentID: docID)
        XCTAssertEqual(branchState.headVersionID(for: "본편"), docVersion.id)
        XCTAssertEqual(branchState.resolveDocumentHead(for: "본편", in: versions)?.id, docVersion.id)

        let brief = try XCTUnwrap(ManuscriptResumeBrief.build(for: docID, in: XCTUnwrap(session.activeProject)))
        XCTAssertFalse(brief.hasUnsavedVersionChanges)

        // Switching to the same branch or round-tripping through another branch preserves the full manuscript.
        try await ManuscriptVersionActions.switchBranch(
            to: "본편",
            session: session,
            requests: requests,
            undoManager: undo
        )
        XCTAssertEqual(session.selectedDocument?.body, fullBody)

        // Simulate legacy state where headVersionID was pointing to a .scene version.
        var legacyBranchState = branchState
        legacyBranchState.branches = [.init(name: "본편", headVersionID: sceneVersion.id, updatedAt: sceneVersion.createdAt)]
        XCTAssertEqual(legacyBranchState.resolveDocumentHead(for: "본편", in: versions)?.id, docVersion.id)

        // A branch that only has a .scene version and no .document version must refuse switchBranch.
        var sceneOnlyVersion = sceneVersion
        sceneOnlyVersion.branchName = "장면전용"
        try session.updateProjectUserData([
            sceneOnlyVersion.userDataKey: JSONEncoder().encode(sceneOnlyVersion)
        ], projectID: project.id)
        do {
            try await ManuscriptVersionActions.switchBranch(
                to: "장면전용",
                session: session,
                requests: requests,
                undoManager: undo
            )
            XCTFail("Expected unknownBranch when target branch has only scene versions")
        } catch let error as ManuscriptVersionError {
            XCTAssertEqual(error, .unknownBranch)
        }
        XCTAssertEqual(session.selectedDocument?.body, fullBody)
    }

    // MARK: - F02 & F03: 3-way merge alignment and lossless formatting preservation

    func testF02AndF03ThreeWayMergeAlignsInsertionsDeletionsAndPreservesExactFormatting() {
        // 1. Prepending a paragraph on ours while editing a later paragraph on theirs merges cleanly.
        let base1 = "A\n\nM\n\nB\n"
        let ours1 = "P\n\nA\n\nM\n\nB\n"
        let theirs1 = "A\n\nM\n\nB2\n"
        let merge1 = ManuscriptThreeWayMerge.merge(base: base1, ours: ours1, theirs: theirs1)
        XCTAssertFalse(merge1.hasConflicts)
        XCTAssertEqual(merge1.resolvedText(), "P\n\nA\n\nM\n\nB2\n")

        // 2. Mutual adjacent deletions (base = A, B; ours = B; theirs = A) surface a conflict instead of silently dropping A.
        let base2 = "A\n\nB\n"
        let ours2 = "B\n"
        let theirs2 = "A\n"
        let merge2 = ManuscriptThreeWayMerge.merge(base: base2, ours: ours2, theirs: theirs2)
        XCTAssertEqual(merge2.conflicts.count, 1)
        XCTAssertEqual(merge2.resolvedText(using: [0: .ours]), "B\n")
        XCTAssertEqual(merge2.resolvedText(using: [0: .theirs]), "A\n")
        XCTAssertEqual(merge2.resolvedText(using: [0: .both]), "B\n\nA\n")

        // 3. Non-overlapping deletions separated by an unchanged anchor merge cleanly.
        let base3 = "A\n\nM\n\nB\n"
        let ours3 = "M\n\nB\n"
        let theirs3 = "A\n\nM\n"
        let merge3 = ManuscriptThreeWayMerge.merge(base: base3, ours: ours3, theirs: theirs3)
        XCTAssertFalse(merge3.hasConflicts)
        XCTAssertEqual(merge3.resolvedText(), "M\n")

        // 4. Identical inputs with leading indentation, multiple blank lines, and no trailing newline stay byte-exact.
        let formatted = "  - 중첩\n    - 하위\n\n\n끝"
        let sameMerge = ManuscriptThreeWayMerge.merge(base: formatted, ours: formatted, theirs: formatted)
        XCTAssertFalse(sameMerge.hasConflicts)
        XCTAssertEqual(sameMerge.resolvedText(), formatted)

        // 5. Partial edits preserve custom indentation, triple blank lines, and EOF newline absence in untouched blocks.
        let formattedBase = "1문단\n\n  - 중첩 1\n    - 중첩 2\n\n\n3문단"
        let formattedOurs = "1문단 수정\n\n  - 중첩 1\n    - 중첩 2\n\n\n3문단"
        let formattedTheirs = "1문단\n\n  - 중첩 1\n    - 중첩 2\n\n\n3문단 수정"
        let formattedMerge = ManuscriptThreeWayMerge.merge(
            base: formattedBase,
            ours: formattedOurs,
            theirs: formattedTheirs
        )
        XCTAssertFalse(formattedMerge.hasConflicts)
        XCTAssertEqual(formattedMerge.resolvedText(), "1문단 수정\n\n  - 중첩 1\n    - 중첩 2\n\n\n3문단 수정")
    }

    // MARK: - F10: createBranch(from: nil) preserves common ancestor lineage

    func testF10CreateBranchFromCurrentManuscriptPreservesParentLineage() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(
            store: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            autosaveDelay: .seconds(3600)
        )
        var project = projectFixture()
        let docID = project.documents[0].id
        let initialBody = "1문단 시작\n\n2문단 중간\n\n3문단 끝\n"
        project.documents[0].body = initialBody
        try await session.saveAndActivate(project)

        let requests = ProjectEditorRequests()
        let editor = BlockTextView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.documentUndoManager = undo
        editor.load(markdown: initialBody)
        requests.register(editor, for: .init(projectID: project.id, documentID: docID))

        // Branching with baseVersion == nil when no version has been saved yet:
        let altStart = try await ManuscriptVersionActions.createBranch(
            name: "대안 흐름",
            from: nil,
            session: session,
            requests: requests,
            undoManager: undo
        )
        let userData = try XCTUnwrap(session.activeProject?.userData)
        let versions = try ManuscriptVersion.list(in: userData, documentID: docID)
        let branchState = try ManuscriptBranchState.loadValid(in: userData, documentID: docID)
        let mainHead = try XCTUnwrap(branchState.resolveDocumentHead(for: "본편", in: versions))
        XCTAssertTrue(altStart.parentIDs.contains(mainHead.id))
        XCTAssertEqual(
            ManuscriptVersion.lowestCommonAncestor(of: mainHead.id, and: altStart.id, in: versions)?.id,
            mainHead.id
        )

        // Edit 3rd paragraph on "대안 흐름", switch to "본편", edit 1st paragraph, and preview merge:
        let altBody = "1문단 시작\n\n2문단 중간\n\n3문단 대안 끝\n"
        session.updateSelectedDocumentBody(altBody)
        editor.load(markdown: altBody)
        _ = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "대안 수정")

        try await ManuscriptVersionActions.switchBranch(
            to: "본편",
            session: session,
            requests: requests,
            undoManager: undo
        )
        let mainBody = "1문단 본편 시작\n\n2문단 중간\n\n3문단 끝\n"
        session.updateSelectedDocumentBody(mainBody)
        editor.load(markdown: mainBody)
        let preview = try ManuscriptVersionActions.previewMerge(
            from: "대안 흐름",
            in: XCTUnwrap(session.selectedDocumentSnapshot)
        )
        XCTAssertEqual(preview.base?.id, mainHead.id)
        XCTAssertFalse(preview.merge.hasConflicts)
        XCTAssertEqual(preview.merge.resolvedText(), "1문단 본편 시작\n\n2문단 중간\n\n3문단 대안 끝\n")
    }

    // MARK: - F11: Distinct branch names never collide on Git ref paths

    func testF11ProjectGitRepositorySeparatesRefsForCollidingBranchNames() throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalProjectFileSystem()
        let docID = WritingDocumentID()

        let spaceBranch = "다른 결말"
        let hyphenBranch = "다른-결말"
        let symbolBranchA = "!?*"
        let symbolBranchB = "???"
        let longPrefix = String(repeating: "가", count: 70)
        let longBranchA = longPrefix + "-1"
        let longBranchB = longPrefix + "-2"

        let allBranches = [spaceBranch, hyphenBranch, symbolBranchA, symbolBranchB, longBranchA, longBranchB]
        let refPaths = Set(allBranches.map { ProjectGitRepository.branchRefPath(documentID: docID, branch: $0) })
        XCTAssertEqual(refPaths.count, allBranches.count)

        let c1 = try ProjectGitRepository.commitManuscript(
            at: root,
            documentID: docID,
            branch: spaceBranch,
            message: "공백 브랜치 첫 커밋",
            text: "공백 브랜치 원고 1",
            files: files
        )
        let c2 = try ProjectGitRepository.commitManuscript(
            at: root,
            documentID: docID,
            branch: hyphenBranch,
            message: "하이픈 브랜치 첫 커밋",
            text: "하이픈 브랜치 원고 1",
            files: files
        )
        XCTAssertNotEqual(c1.sha, c2.sha)
        XCTAssertTrue(c2.parentSHAs.isEmpty, "Different branch with similar display name must not inherit c1 as fallback parent")

        let c1Next = try ProjectGitRepository.commitManuscript(
            at: root,
            documentID: docID,
            branch: spaceBranch,
            message: "공백 브랜치 둘째 커밋",
            text: "공백 브랜치 원고 2",
            files: files
        )
        XCTAssertEqual(c1Next.parentSHAs, [c1.sha])
    }

    // MARK: - F12: Backup restore preserves Git objects and filters missing parent SHAs

    func testF12BackupRestorePreservesGitObjectsAndValidatesParentSHAs() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(
            store: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            autosaveDelay: .seconds(3600)
        )
        var project = projectFixture()
        let docID = project.documents[0].id
        project.documents[0].body = "백업 전 초고 본문\n"
        try await session.saveAndActivate(project)

        let requests = ProjectEditorRequests()
        let v1 = try await ManuscriptVersionActions.capture(
            session: session,
            requests: requests,
            label: "백업 시점 버전"
        )
        let v1SHA = try XCTUnwrap(v1.gitCommitSHA)

        // Advance the live project so previous-project.json captures the state with v1.
        session.updateSelectedDocumentBody("백업 이후 변경된 본문\n")
        try await session.saveNow()

        let preview = try await store.previousBackup(id: project.id)
        let restored = try await store.prepareBackupRestore(preview)
        let restoredVersions = try ManuscriptVersion.list(in: restored.userData, documentID: docID)
        let restoredV1 = try XCTUnwrap(restoredVersions.first)
        let restoredSHA = try XCTUnwrap(restoredV1.gitCommitSHA)

        let blobText = try await store.readManuscriptGitBlob(
            projectID: restored.id,
            commitSHA: restoredSHA,
            documentID: docID
        )
        XCTAssertEqual(blobText, "백업 전 초고 본문\n")
        XCTAssertEqual(restoredSHA, v1SHA)

        // Subsequent commit on the restored project must have a valid existing parent SHA, and bogus parent SHAs must be dropped.
        let bogusParent = String(repeating: "deadbeef", count: 5)
        let nextCommit = try await store.commitManuscriptGitVersion(
            projectID: restored.id,
            documentID: docID,
            branch: "본편",
            message: "복원 후 후속 커밋",
            text: "복원 후 이어쓴 본문\n",
            parentSHAs: [restoredSHA, bogusParent]
        )
        XCTAssertEqual(nextCommit.parentSHAs, [restoredSHA])
    }

    // MARK: - F13: Branch switch Undo/Redo atomically restores both body and activeBranch

    func testF13SwitchBranchUndoAndRedoRestoreBothBodyAndActiveBranch() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(
            store: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            autosaveDelay: .seconds(3600)
        )
        var project = projectFixture()
        let docID = project.documents[0].id
        let mainBody = "본편 원고 내용입니다.\n"
        project.documents[0].body = mainBody
        try await session.saveAndActivate(project)

        let requests = ProjectEditorRequests()
        let editor = BlockTextView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.documentUndoManager = undo
        editor.load(markdown: mainBody)
        requests.register(editor, for: .init(projectID: project.id, documentID: docID))

        let base = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "본편 초고")
        _ = try await ManuscriptVersionActions.createBranch(
            name: "다른 결말",
            from: base,
            session: session,
            requests: requests,
            undoManager: undo
        )
        let altBody = "다른 결말 원고 내용입니다.\n"
        session.updateSelectedDocumentBody(altBody)
        editor.load(markdown: altBody)
        _ = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "다른 결말 저장")

        // Switch from "다른 결말" to "본편"
        try await ManuscriptVersionActions.switchBranch(
            to: "본편",
            session: session,
            requests: requests,
            undoManager: undo
        )
        XCTAssertEqual(session.selectedDocument?.body, mainBody)
        XCTAssertEqual(
            try ManuscriptBranchState.loadValid(in: XCTUnwrap(session.activeProject?.userData), documentID: docID).activeBranch,
            "본편"
        )

        // Undo the branch switch -> must restore BOTH altBody and activeBranch == "다른 결말"
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(session.selectedDocument?.body, altBody)
        XCTAssertEqual(editor.serialize(), altBody)
        XCTAssertEqual(
            try ManuscriptBranchState.loadValid(in: XCTUnwrap(session.activeProject?.userData), documentID: docID).activeBranch,
            "다른 결말"
        )

        // Redo the branch switch -> must restore BOTH mainBody and activeBranch == "본편"
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(session.selectedDocument?.body, mainBody)
        XCTAssertEqual(editor.serialize(), mainBody)
        XCTAssertEqual(
            try ManuscriptBranchState.loadValid(in: XCTUnwrap(session.activeProject?.userData), documentID: docID).activeBranch,
            "본편"
        )
    }

    // MARK: - F14: Per-document corruption isolation and fail-closed metadata loading

    func testF14CorruptForeignRecordIsIsolatedAndCorruptLocalMetadataFailsClosed() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(
            store: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            autosaveDelay: .seconds(3600)
        )
        let docA = WritingDocument(id: WritingDocumentID(), title: "1장", body: "1장 정상 원고\n", kind: .manuscript)
        let docB = WritingDocument(id: WritingDocumentID(), title: "2장", body: "2장 원고\n", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "소설", mode: .fiction, documents: [docA, docB])
        try await session.saveAndActivate(project)

        let requests = ProjectEditorRequests()
        let vA = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "1장 첫 기록")

        // 1. Insert a future/corrupt version record for docB; listing docA must still succeed.
        let foreignVersionID = UUID()
        let foreignCorruptJSON = """
        {"formatVersion":99,"id":"\(foreignVersionID.uuidString)","documentID":"\(docB.id.rawValue.uuidString)"}
        """
        let foreignKey = "manuscript-version-" + foreignVersionID.uuidString.lowercased()
        try session.updateProjectUserData([foreignKey: Data(foreignCorruptJSON.utf8)], projectID: project.id)

        let currentData = try XCTUnwrap(session.activeProject?.userData)
        let listA = try ManuscriptVersion.list(in: currentData, documentID: docA.id)
        XCTAssertEqual(listA, [vA])
        XCTAssertThrowsError(try ManuscriptVersion.list(in: currentData, documentID: docB.id)) { error in
            XCTAssertEqual(error as? ManuscriptVersionError, .invalidRecord)
        }

        // 2. Corrupting docA's branch state must cause loadValid and capture to fail closed without overwriting the bytes.
        let branchKeyA = ManuscriptBranchState.userDataKey(for: docA.id)
        let corruptBranchBytes = Data("corrupt-branch-state".utf8)
        try session.updateProjectUserData([branchKeyA: corruptBranchBytes], projectID: project.id)

        XCTAssertThrowsError(
            try ManuscriptBranchState.loadValid(
                in: XCTUnwrap(session.activeProject?.userData),
                documentID: docA.id
            )
        ) { error in
            XCTAssertEqual(error as? ManuscriptVersionError, .invalidRecord)
        }

        session.updateSelectedDocumentBody("1장 수정된 원고\n")
        do {
            _ = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "실패해야 하는 기록")
            XCTFail("Expected capture to fail closed when branch state is corrupt")
        } catch let error as ManuscriptVersionError {
            XCTAssertEqual(error, .invalidRecord)
        }
        XCTAssertEqual(session.activeProject?.userData[branchKeyA], corruptBranchBytes)

        let safetyResult = ManuscriptVersionActions.captureSafetySnapshotIfNeeded(
            for: .init(projectID: project.id, documentID: docA.id),
            in: session
        )
        XCTAssertNil(safetyResult)
        XCTAssertEqual(session.activeProject?.userData[branchKeyA], corruptBranchBytes)
    }

    // MARK: - H2: Merge preview/apply rejects stale head or concurrent mutations

    func testH2ApplyMergeRejectsWhenBranchHeadMovesAfterPreview() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(
            store: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            autosaveDelay: .seconds(3600)
        )
        var project = projectFixture()
        let docID = project.documents[0].id
        let baseBody = "1문단\n\n2문단\n"
        project.documents[0].body = baseBody
        try await session.saveAndActivate(project)

        let requests = ProjectEditorRequests()
        let editor = BlockTextView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.documentUndoManager = undo
        editor.load(markdown: baseBody)
        requests.register(editor, for: .init(projectID: project.id, documentID: docID))

        let base = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "기준")
        _ = try await ManuscriptVersionActions.createBranch(
            name: "비교갈림길",
            from: base,
            session: session,
            requests: requests,
            undoManager: undo
        )
        let altBody = "1문단\n\n2문단 대안\n"
        session.updateSelectedDocumentBody(altBody)
        editor.load(markdown: altBody)
        _ = try await ManuscriptVersionActions.capture(session: session, requests: requests, label: "대안 1")

        try await ManuscriptVersionActions.switchBranch(
            to: "본편",
            session: session,
            requests: requests,
            undoManager: undo
        )
        let previewSnapshot = try XCTUnwrap(session.selectedDocumentSnapshot)
        let preview = try ManuscriptVersionActions.previewMerge(
            from: "비교갈림길",
            in: previewSnapshot
        )

        // Mutate the manuscript after preview is computed -> applyMerge must reject with staleRuntime
        session.updateSelectedDocumentBody("1문단 미리보기 이후 변경\n\n2문단\n")
        editor.load(markdown: "1문단 미리보기 이후 변경\n\n2문단\n")
        do {
            _ = try await ManuscriptVersionActions.applyMerge(
                from: "비교갈림길",
                resolutions: [:],
                expectedIdentity: previewSnapshot.identity,
                expectedSourceHeadID: preview.sourceHead.id,
                session: session,
                requests: requests,
                undoManager: undo
            )
            XCTFail("Expected applyMerge to reject stale preview after manuscript edit")
        } catch let error as ProjectSessionError {
            XCTAssertEqual(error, .staleRuntime)
        }
    }
}
