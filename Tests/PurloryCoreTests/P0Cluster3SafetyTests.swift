import AppKit
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryIntelligence
@testable import PurloryStorage
@testable import PurloryWorkspaceUI

final class P0Cluster3SafetyTests: XCTestCase {

    // MARK: - 1. ProjectSession.createDocument with invalid folder must not invoke willTransition

    @MainActor
    func testCreateDocumentWithInvalidFolderDoesNotTriggerWillTransition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-P0-CreateDoc-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Purlory.P0.CreateDoc.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let session = ProjectSession(store: ProjectStore(root: root), defaults: defaults)
        try await ProjectCreationCoordinator(session: session).createProject(title: "Draft", mode: .general)

        var willTransitionCount = 0
        session.willTransition = { willTransitionCount += 1 }

        let created = session.createDocument(title: "Broken", kind: .manuscript, in: UUID())
        XCTAssertNil(created)
        XCTAssertEqual(willTransitionCount, 0, "Invalid folder must fail before willTransition locks the editor")
    }

    // MARK: - 3. ProjectWriterEditing.override deduplicates by (kind, key) not only UUID

    @MainActor
    func testWriterOverrideDeduplicatesByKindAndKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-P0-Override-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Purlory.P0.Override.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let session = ProjectSession(store: ProjectStore(root: root), defaults: defaults)
        try await ProjectCreationCoordinator(session: session).createProject(title: "Draft", mode: .fiction)

        let id1 = try XCTUnwrap(session.runtimeIdentity)
        try ProjectWriterEditing.perform(
            .override(NarrativeOverride(kind: .sceneType, key: "scene-1", value: "회상")),
            in: session,
            identity: id1
        )
        let id2 = try XCTUnwrap(session.runtimeIdentity)
        // New NarrativeOverride instance has a fresh UUID, same (kind, key).
        try ProjectWriterEditing.perform(
            .override(NarrativeOverride(kind: .sceneType, key: "scene-1", value: "현재")),
            in: session,
            identity: id2
        )

        let snapshot = try XCTUnwrap(session.selectedDocumentSnapshot)
        let docID = snapshot.identity.key.documentID
        let data = try WriterDocumentData.decode(snapshot.userData[WriterDocumentData.key(for: docID)], documentID: docID)
        XCTAssertEqual(data.narrativeOverrides.count, 1, "Same (kind, key) override must replace rather than duplicate")
        XCTAssertEqual(data.narrativeOverrides.first?.value, "현재")
    }

    // MARK: - 4. WorkspaceWritingStatistics concurrent thread safety

    func testWorkspaceWritingStatisticsConcurrentAccessIsSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for idx in 0..<24 {
                group.addTask {
                    let stats = WorkspaceWritingStatistics(text: "문단 \(idx)\n둘째 줄 \(idx)")
                    XCTAssertGreaterThan(stats.characters, 0)
                    XCTAssertEqual(stats.paragraphs, 2)
                }
            }
        }
        XCTAssertGreaterThan(WorkspaceWritingStatistics.scanCount, 0)
    }

    // MARK: - 5. Custom dark palette must be recognized as dark

    func testCustomDarkPaletteThemeIsRecognizedAsDark() {
        let customDarkPalette = PurloryPalette(hexes: [0x16171A, 0x1E2025, 0x262930, 0x5CC8B8, 0x3D998C])
        let customDark = PurloryTheme.of(.dark, palette: customDarkPalette)
        XCTAssertNotEqual(customDark, PurloryTheme.dark, "Custom dark theme differs from default .dark")
        XCTAssertTrue(customDark.isDark, "Custom dark theme must report isDark == true")
        XCTAssertTrue(PurloryTheme.dark.isDark)
        XCTAssertFalse(PurloryTheme.light.isDark)
    }

    // MARK: - 6. ProjectGitRepository handles duplicate backup envelopes without crashing and empty zlib

    func testProjectGitRepositoryHandlesDuplicateBackupVersionIDsWithoutCrashing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-P0-GitDup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dupID = UUID()
        let docID = WritingDocumentID()
        let doc = WritingDocument(id: docID, title: "Doc", body: "hello", kind: .manuscript)
        let version = ManuscriptVersion(
            id: dupID,
            documentID: docID,
            createdAt: Date(timeIntervalSince1970: 1000),
            label: "v1",
            scope: .document,
            text: "hello",
            contentVersion: SceneContentVersion(rawValue: "rev-hello"),
            sourceRevision: "rev-1",
            sourceStart: 0,
            headingPath: [],
            heading: nil,
            parentIDs: [],
            branchName: "본편",
            gitCommitSHA: nil
        )
        let bytes = try JSONEncoder().encode(version)
        let project = WritingProject(
            id: WritingProjectID(),
            title: "Test",
            mode: .general,
            documents: [doc],
            userData: [
                "manuscript-version-a": bytes,
                "manuscript-version-b": bytes,
            ]
        )

        var mutableProject = project
        let changed = try ProjectGitRepository.restoreForBackup(
            from: root,
            to: root,
            project: &mutableProject,
            files: LocalProjectFileSystem()
        )
        XCTAssertTrue(changed)
    }

    func testProjectGitRepositoryZlibCompressHandlesEmptyData() throws {
        let compressed = try ProjectGitRepository.zlibCompress(Data())
        XCTAssertFalse(compressed.isEmpty)
    }

    // MARK: - 7. ProjectNavigatorTrashView excludes folder-bundled docs from standalone list

    @MainActor
    func testTrashStandaloneDocumentsExcludesFolderBundledDocuments() {
        let docInFolder = WritingDocument(id: WritingDocumentID(), title: "InFolder", body: "", kind: .manuscript)
        let standaloneDoc = WritingDocument(id: WritingDocumentID(), title: "Standalone", body: "", kind: .manuscript)
        let folderID = UUID()
        let project = WritingProject(
            id: WritingProjectID(),
            title: "Test",
            mode: .general,
            documents: [docInFolder, standaloneDoc],
            trashedDocumentIDs: [docInFolder.id, standaloneDoc.id]
        )
        let bundle = ProjectNavigation.TrashBundle(
            folders: [folderID],
            documents: [docInFolder.id]
        )
        let standalone = ProjectNavigatorTrashView.standaloneDocuments(
            in: project,
            trashBundles: [folderID: bundle]
        )
        XCTAssertEqual(standalone.map(\.id), [standaloneDoc.id])
    }
}
