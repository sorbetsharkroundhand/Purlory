import AppKit
import Foundation
@testable import PurloryCore
@testable import PurloryStorage
@testable import PurloryWorkspaceUI

/// Shared temporary project/session fixture used across workspace, navigation, search, and shutdown tests.
@MainActor
struct LegacyBoundaryFixture {
    let root: URL
    let legacyRoot: URL
    let defaults: UserDefaults
    let suite: String
    let store: ProjectStore
    let session: ProjectSession
    let project: WritingProject

    init(
        failProjectWrites: Bool = false,
        projectTitle: String = "Project",
        mode: WritingMode = .general,
        autosaveDelay: Duration = .seconds(3600)
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-LegacyBoundary-\(UUID())")
        legacyRoot = root.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        suite = "Purlory-LegacyBoundary-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        store = ProjectStore(root: root.appendingPathComponent("Projects"))
        project = WritingProject(
            id: WritingProjectID(),
            title: projectTitle,
            mode: mode,
            documents: [
                WritingDocument(
                    id: WritingDocumentID(),
                    title: "Manuscript",
                    body: "original project",
                    kind: .manuscript
                )
            ]
        )
        try await store.save(project)
        try await store.activate(id: project.id)
        let sessionStore = failProjectWrites
            ? ProjectStore(
                root: root.appendingPathComponent("Projects"),
                fileSystem: FailingProjectFiles(fragment: "/Documents/")
            )
            : store
        session = ProjectSession(store: sessionStore, defaults: defaults, autosaveDelay: autosaveDelay)
        try await session.bootstrap()
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyRoot.path)
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Deterministic `NSWindow` subclass exposing an isolated `UndoManager` for editor tests.
@MainActor
final class LegacyUndoWindow: NSWindow {
    let testUndo = UndoManager()
    override var undoManager: UndoManager? { testUndo }
}
