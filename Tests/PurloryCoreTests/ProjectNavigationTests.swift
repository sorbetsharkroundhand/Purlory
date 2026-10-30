@testable import PurloryIntelligence
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ProjectNavigationTests: XCTestCase {
    private func project() -> WritingProject {
        WritingProject(id: WritingProjectID(), title: "Book", mode: .general,
            documents: [WritingDocument(id: WritingDocumentID(), title: "A", body: "**한글🙂**", kind: .manuscript),
                        WritingDocument(id: WritingDocumentID(), title: "B", body: "Original", kind: .note)])
    }
    func testNestedOrganizationRoundTripsWithoutChangingManuscriptsOrOtherUserData() throws {
        var project = project(), navigation = ProjectNavigation()
        project.userData["writer-record"] = Data("keep".utf8)
        let parent = ProjectFolder(name: "Part 1"), child = ProjectFolder(name: "Scenes", parentID: parent.id)
        try navigation.apply(.createFolder(parent), to: &project)
        try navigation.apply(.createFolder(child), to: &project)
        let id = project.documents[0].id
        try navigation.apply(.drop(.document(id), .inside(.folder(child.id))), to: &project)
        try navigation.apply(.date(id, Date(timeIntervalSince1970: 123)), to: &project)
        let decoded = try ProjectNavigation.read(JSONDecoder().decode(WritingProject.self, from: JSONEncoder().encode(project)))
        XCTAssertEqual(decoded, navigation)
        XCTAssertEqual(decoded.path(child.id), "Part 1 / Scenes")
        XCTAssertEqual(project.documents.first { $0.id == id }?.body, "**한글🙂**")
        XCTAssertEqual(project.userData["writer-record"], Data("keep".utf8))
        XCTAssertEqual(decoded.rows(in: project, collapsed: [parent.id]).count, 2)
    }
    func testFolderMoveRejectsCyclesAndLeavesPublishedProjectUntouched() throws {
        var project = project(), navigation = ProjectNavigation()
        let parent = ProjectFolder(), child = ProjectFolder(parentID: parent.id)
        try navigation.apply(.createFolder(parent), to: &project)
        try navigation.apply(.createFolder(child), to: &project)
        let before = project
        XCTAssertThrowsError(try navigation.apply(.drop(.folder(parent.id), .inside(.folder(child.id))), to: &project))
        XCTAssertEqual(project, before)
    }
    func testLegacyNewFolderAndGroupedFileOrder() throws {
        var project = project(), navigation = ProjectNavigation()
        let old = ProjectFolder(name: "Existing"), new = ProjectFolder(name: "New")
        try navigation.apply(.createFolder(old), to: &project)
        try navigation.apply(.createFolder(new), to: &project)
        XCTAssertEqual(navigation.visibleFolders(in: nil).map(\.id), [new.id, old.id])
        let ids = project.documents.map(\.id), bodies = project.documents.map(\.body)
        try navigation.apply(.drop(.document(ids[0]), .inside(.document(ids[1]))), to: &project)
        XCTAssertEqual(project.documents.map(\.id), [ids[1], ids[0]])
        XCTAssertEqual(project.documents.map(\.body), bodies.reversed())
        XCTAssertEqual(navigation.visibleFolders(in: nil).map(\.id).prefix(2), [new.id, old.id])
        XCTAssertEqual(try ProjectNavigation.read(project), navigation)
    }
    func testRestoringFolderDoesNotRestorePreviouslyTrashedDocument() throws {
        var project = project(), navigation = ProjectNavigation()
        let ids = project.documents.map(\.id), folder = ProjectFolder()
        try navigation.apply(.createFolder(folder), to: &project)
        for id in ids { try navigation.apply(.drop(.document(id), .inside(.folder(folder.id))), to: &project) }
        try navigation.apply(.trash(.document(ids[0])), to: &project)
        try navigation.apply(.trash(.folder(folder.id)), to: &project)
        try navigation.apply(.restore(.folder(folder.id)), to: &project)
        XCTAssertEqual(project.trashedDocumentIDs, [ids[0]])
        XCTAssertTrue(navigation.trashedFolders.isEmpty)
    }
    func testRestoredDocumentEscapesTrashedFolderAndSurvivesItsPurge() throws {
        var project = project(), navigation = ProjectNavigation()
        let id = project.documents[0].id, folder = ProjectFolder()
        try navigation.apply(.createFolder(folder), to: &project)
        try navigation.apply(.drop(.document(id), .inside(.folder(folder.id))), to: &project)
        try navigation.apply(.trash(.folder(folder.id)), to: &project)
        try navigation.apply(.restore(.document(id)), to: &project)
        try navigation.apply(.purge(.folder(folder.id)), to: &project)
        XCTAssertNil(navigation.documentFolders[id])
        XCTAssertTrue(project.documents.contains { $0.id == id })
    }
    func testGroupingAndSiblingOrderPreserveRichBodies() throws {
        var project = project(), navigation = ProjectNavigation()
        let originals = Dictionary(uniqueKeysWithValues: project.documents.map { ($0.id, $0.body) })
        let ids = project.documents.map(\.id)
        try navigation.apply(.drop(.document(ids[0]), .inside(.document(ids[1]))), to: &project)
        XCTAssertEqual(navigation.folders.count, 1)
        XCTAssertEqual(navigation.documentFolders[ids[0]], navigation.documentFolders[ids[1]])
        try navigation.apply(.drop(.document(ids[1]), .before(.document(ids[0]))), to: &project)
        XCTAssertEqual(project.documents.map(\.id), ids.reversed())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: project.documents.map { ($0.id, $0.body) }), originals)
    }

    func testNavigatorSortModes() throws {
        let docA = WritingDocument(id: WritingDocumentID(), title: "나목", body: "1", kind: .manuscript)
        let docB = WritingDocument(id: WritingDocumentID(), title: "가시리", body: "2", kind: .manuscript)
        let docC = WritingDocument(id: WritingDocumentID(), title: "다람쥐", body: "3", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Sort Test", mode: .general, documents: [docA, docB, docC])
        var nav = ProjectNavigation()
        nav.createdDates[docA.id] = Date(timeIntervalSince1970: 100)
        nav.createdDates[docB.id] = Date(timeIntervalSince1970: 300)
        nav.createdDates[docC.id] = Date(timeIntervalSince1970: 200)

        // Manual order: [docA, docB, docC]
        let manualRows = nav.rows(in: project, collapsed: [], sortMode: .manual)
        XCTAssertEqual(manualRows.compactMap { if case .document(let id) = $0.node { return id } else { return nil } },
                       [docA.id, docB.id, docC.id])

        // Title ascending (가나다순): 가시리(B) -> 나목(A) -> 다람쥐(C)
        let ascRows = nav.rows(in: project, collapsed: [], sortMode: .titleAscending)
        XCTAssertEqual(ascRows.compactMap { if case .document(let id) = $0.node { return id } else { return nil } },
                       [docB.id, docA.id, docC.id])

        // Title descending: 다람쥐(C) -> 나목(A) -> 가시리(B)
        let descRows = nav.rows(in: project, collapsed: [], sortMode: .titleDescending)
        XCTAssertEqual(descRows.compactMap { if case .document(let id) = $0.node { return id } else { return nil } },
                       [docC.id, docA.id, docB.id])

        // Date descending (최신순): B(300) -> C(200) -> A(100)
        let dateDescRows = nav.rows(in: project, collapsed: [], sortMode: .dateDescending)
        XCTAssertEqual(dateDescRows.compactMap { if case .document(let id) = $0.node { return id } else { return nil } },
                       [docB.id, docC.id, docA.id])

        let dateAscRows = nav.rows(in: project, collapsed: [], sortMode: .dateAscending)
        XCTAssertEqual(dateAscRows.compactMap { if case .document(let id) = $0.node { return id } else { return nil } },
                       [docA.id, docC.id, docB.id])
    }

    @MainActor func testNavigatorDropDestinationPreservesLegacyZonesAndRejectsSelfDrop() async throws {
        final class FlippedContainer: NSView { override var isFlipped: Bool { true } }
        let docFolderChild = WritingDocument(id: WritingDocumentID(), title: "폴더내문서", body: "1", kind: .manuscript)
        let docRootA = WritingDocument(id: WritingDocumentID(), title: "루트문서A", body: "2", kind: .manuscript)
        let docRootB = WritingDocument(id: WritingDocumentID(), title: "루트문서B", body: "3", kind: .manuscript)
        var project = WritingProject(id: WritingProjectID(), title: "Drop Test", mode: .general,
                                     documents: [docFolderChild, docRootA, docRootB])
        let folder = ProjectFolder(name: "기존폴더")
        var nav = ProjectNavigation()
        try nav.apply(.createFolder(folder), to: &project)
        try nav.apply(.drop(.document(docFolderChild.id), .inside(.folder(folder.id))), to: &project)

        let controller = ProjectNavigatorController()
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("purlory-nav-drop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = ProjectStore(root: rootURL)
        try await store.save(project)
        let suite = "purlory.nav-drop.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = ProjectSession(store: store, defaults: defaults)
        try await session.activateProject(id: project.id)
        let requests = ProjectEditorRequests()
        controller.configure(session: session, requests: requests, completion: nil)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = FlippedContainer(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        window.contentView = root

        let rowChild = ProjectNavigatorRowDragView(frame: NSRect(x: 0, y: 0, width: 200, height: 38))
        rowChild.node = .document(docFolderChild.id); rowChild.owner = controller
        let rowRootA = ProjectNavigatorRowDragView(frame: NSRect(x: 0, y: 40, width: 200, height: 38))
        rowRootA.node = .document(docRootA.id); rowRootA.owner = controller
        let rowRootB = ProjectNavigatorRowDragView(frame: NSRect(x: 0, y: 80, width: 200, height: 38))
        rowRootB.node = .document(docRootB.id); rowRootB.owner = controller
        let rowBackground = ProjectNavigatorRowDragView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        rowBackground.node = nil; rowBackground.owner = controller

        root.addSubview(rowChild)
        root.addSubview(rowRootA)
        root.addSubview(rowRootB)
        root.addSubview(rowBackground)

        // 0. Dropping on empty background below rows returns .root
        let bgDest = ProjectNavigatorController.destination(
            for: .document(docFolderChild.id), at: root.convert(CGPoint(x: 50, y: 200), to: nil), in: root)
        XCTAssertEqual(bgDest?.1, .root)

        // 1. Self-drop on docFolderChild must return nil (not fall through to rowBackground .root)
        XCTAssertNil(ProjectNavigatorController.destination(
            for: .document(docFolderChild.id), at: root.convert(CGPoint(x: 50, y: 19), to: nil), in: root))

        // Edge insertion adopts the target's parent, as in the legacy navigator.
        XCTAssertEqual(ProjectNavigatorController.destination(
            for: .document(docRootA.id), at: root.convert(CGPoint(x: 50, y: 35), to: nil), in: root)?.1, .after(.document(docFolderChild.id)))

        // The center groups files without a modifier, matching the original navigator.
        let mergeDest = ProjectNavigatorController.destination(
            for: .document(docRootB.id), at: root.convert(CGPoint(x: 50, y: 59), to: nil), in: root)
        XCTAssertEqual(mergeDest?.1, .inside(.document(docRootA.id)))
    }
}
