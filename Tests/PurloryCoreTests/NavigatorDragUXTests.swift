@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class NavigatorDragUXTests: XCTestCase {
    func testDropCannotBeClaimedByARowOutsideTheNavigatorBounds() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second")); await h.layout()
        let owner = try XCTUnwrap(try row(a, in: h).owner)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let overflow = ProjectNavigatorRowDragView(frame: CGRect(x: 0, y: 0, width: 500, height: 38))
        overflow.node = .document(a); overflow.owner = owner; root.addSubview(overflow)
        XCTAssertNil(ProjectNavigatorController.destination(for: .document(b),
            at: overflow.convert(CGPoint(x: 250, y: 19), to: nil), in: root))
    }

    func testDocumentCanEnterFolderAcrossTheLegacyFolderRow() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let owner = try XCTUnwrap(try row(id, in: h).owner)
        let folder = try XCTUnwrap(owner.createFolder()); await h.layout()
        let target = try XCTUnwrap(h.element("purlory.navigator.drag.folder.\(folder.uuidString)") as? NSView)
        let navigator = try XCTUnwrap(h.requests.spatialWorkspace?.canvas?.hosts[.navigator])
        for y in [CGFloat(1), target.bounds.height - 1] {
            XCTAssertEqual(ProjectNavigatorController.destination(for: .document(id),
                at: target.convert(CGPoint(x: 40, y: y), to: nil), in: navigator)?.1, .inside(.folder(folder)))
        }
        XCTAssertEqual(ProjectNavigatorController.destination(for: .document(id),
            at: target.convert(CGPoint(x: 40, y: target.bounds.midY), to: nil), in: navigator)?.1, .inside(.folder(folder)))
    }

    func testCenterDropGroupsWithoutModifiersWithTargetFirstAndSupportsUndo() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second")); await h.layout()
        let canvas = try XCTUnwrap(h.requests.spatialWorkspace?.canvas)
        do {
            let source = try row(a, in: h), target = try row(b, in: h)
            let start = source.convert(CGPoint(x: 40, y: 18), to: nil)
            let end = target.convert(CGPoint(x: 40, y: target.bounds.midY), to: nil)
            source.mouseDown(with: try event(.leftMouseDown, at: start, window: h.window))
            canvas.continuePanelDrag(try event(.leftMouseDragged, at: end, window: h.window))
            XCTAssertEqual(source.owner?.dropIndicator, .inside(.document(b)))
            canvas.finishPanelDrag(try event(.leftMouseUp, at: end, window: h.window)); await h.layout()
            let organization = try ProjectNavigation.read(try XCTUnwrap(h.fixture.session.activeProject))
            XCTAssertEqual(organization.folders.count, 1)
            XCTAssertEqual(organization.documentFolders[a], organization.documentFolders[b])
            XCTAssertEqual(h.fixture.session.activeProject?.documents.map(\.id), [b, a])
            h.requests.nativeEditor?.undoManager?.undo(); await h.layout()
            XCTAssertTrue(try ProjectNavigation.read(try XCTUnwrap(h.fixture.session.activeProject)).folders.isEmpty)
        }
    }

    func testDocumentEdgeDropReordersWithoutCreatingAFolder() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second")); await h.layout()
        let source = try row(b, in: h), target = try row(a, in: h)
        let owner = try XCTUnwrap(source.owner)
        let point = target.convert(CGPoint(x: 40, y: 1), to: nil)
        let drop = try XCTUnwrap(ProjectNavigatorController.destination(for: .document(b), at: point,
            in: try XCTUnwrap(h.requests.spatialWorkspace?.canvas?.hosts[.navigator])))
        XCTAssertEqual(drop.1, .before(.document(a)))
        owner.performDrop(.document(b), destination: drop.1, project: h.fixture.project.id, epoch: h.fixture.session.activationEpoch)
        let saved = try ProjectNavigation.read(try XCTUnwrap(h.fixture.session.activeProject))
        XCTAssertTrue(saved.folders.isEmpty, "A routine list drag must not manufacture a folder")
        XCTAssertNil(saved.documentFolders[b])
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.navigator.sortMode"), NavigatorSortMode.manual.rawValue,
            "A successful reorder must be visible even when the previous sort was alphabetical")
    }

    func testDraggingOutsideFolderIndentationExtractsDocumentAndCanUndo() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let owner = try XCTUnwrap(try row(id, in: h).owner)
        let parent = try XCTUnwrap(owner.createFolder()), child = try XCTUnwrap(owner.createFolder(in: parent))
        XCTAssertTrue(owner.perform(.drop(.document(id), .inside(.folder(child)))))
        await h.layout()
        let originalBody = h.fixture.session.document(id)?.body
        let canvas = try XCTUnwrap(h.requests.spatialWorkspace?.canvas)
        if let directory = ProcessInfo.processInfo.environment["PURLORY_NAVIGATOR_CAPTURE_DIR"], let host = canvas.hosts[.navigator] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory + "/navigator.png"))
        }
        let source = try row(id, in: h)
        let start = source.convert(CGPoint(x: 40, y: 18), to: nil)
        let end = source.convert(CGPoint(x: 4, y: 18), to: nil)
        source.mouseDown(with: try event(.leftMouseDown, at: start, window: h.window))
        canvas.continuePanelDrag(try event(.leftMouseDragged, at: end, window: h.window))
        XCTAssertEqual(owner.dropIndicator, .root)
        canvas.finishPanelDrag(try event(.leftMouseUp, at: end, window: h.window)); await h.layout()
        XCTAssertNil(try ProjectNavigation.read(try XCTUnwrap(h.fixture.session.activeProject)).documentFolders[id])
        XCTAssertEqual(h.fixture.session.document(id)?.body, originalBody)
        h.requests.nativeEditor?.undoManager?.undo(); await h.layout()
        XCTAssertEqual(try ProjectNavigation.read(try XCTUnwrap(h.fixture.session.activeProject)).documentFolders[id], child)
    }

    func testFolderGutterWorksWithoutScrollingToTheEndOfALongList() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let owner = try XCTUnwrap(try row(id, in: h).owner)
        let folder = try XCTUnwrap(owner.createFolder())
        XCTAssertTrue(owner.perform(.drop(.document(id), .inside(.folder(folder)))))
        for index in 0..<30 { _ = h.fixture.session.createDocument(title: "Document \(index)") }
        await h.layout()
        let navigator = try XCTUnwrap(h.requests.spatialWorkspace?.canvas?.hosts[.navigator])
        let target = try row(id, in: h)
        let point = target.convert(CGPoint(x: 4, y: target.bounds.midY), to: nil)
        XCTAssertGreaterThan(target.visibleRect.height, 20)
        XCTAssertEqual(ProjectNavigatorController.destination(for: .document(id), at: point, in: navigator)?.1, .root,
            "The gutter beside the folder's visible contents must extract the document")
    }

    func testDroppingOnWorkspaceAfterHoveringFolderDoesNotReparentManuscript() async throws {
        let h = try await FramedWorkspaceHarness(width: 1200, reduceMotion: true); defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second")); await h.layout()
        let owner = try XCTUnwrap(try row(b, in: h).owner)
        let folder = try XCTUnwrap(owner.createFolder())
        XCTAssertTrue(owner.perform(.drop(.document(b), .inside(.folder(folder)))))
        let model = try XCTUnwrap(h.requests.spatialWorkspace), canvas = try XCTUnwrap(model.canvas)
        _ = model.close(.document(b)); model.open(a); await h.layout()
        let original = try ProjectNavigation.read(try XCTUnwrap(h.fixture.session.activeProject))
        let source = try row(b, in: h)
        source.mouseDown(with: try event(.leftMouseDown, at: source.convert(CGPoint(x: 40, y: 18), to: nil), window: h.window))
        let folderRow = try XCTUnwrap(h.element("purlory.navigator.drag.folder.\(folder.uuidString)") as? NSView)
        canvas.continuePanelDrag(try event(.leftMouseDragged, at: folderRow.convert(CGPoint(x: 40, y: 17), to: nil), window: h.window))
        let target = try XCTUnwrap(canvas.geometry.tiles[.document(a)])
        let end = canvas.convert(CGPoint(x: target.midX, y: target.midY), to: nil)
        canvas.continuePanelDrag(try event(.leftMouseDragged, at: end, window: h.window))
        XCTAssertNil(owner.dropIndicator)
        canvas.finishPanelDrag(try event(.leftMouseUp, at: end, window: h.window)); await h.layout()
        XCTAssertEqual(try ProjectNavigation.read(try XCTUnwrap(h.fixture.session.activeProject)), original)
        XCTAssertTrue(model.layout.slot(containing: .document(a))?.contains(.document(b)) == true)
    }

    private func row(_ id: WritingDocumentID, in h: FramedWorkspaceHarness) throws -> ProjectNavigatorRowDragView {
        try XCTUnwrap(h.element("purlory.navigator.drag.\(id.rawValue.uuidString)") as? ProjectNavigatorRowDragView)
    }

    func testNestedFolderGutterMovesOneLevelOutAndCancelPreservesMembership() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let owner = try XCTUnwrap(try row(id, in: h).owner)
        let outer = try XCTUnwrap(owner.createFolder()), inner = try XCTUnwrap(owner.createFolder(in: outer))
        XCTAssertTrue(owner.perform(.drop(.document(id), .inside(.folder(inner)))))
        await h.layout()
        let source = try row(id, in: h), canvas = try XCTUnwrap(h.requests.spatialWorkspace?.canvas)
        let start = source.convert(CGPoint(x: 55, y: 18), to: nil)
        let end = source.convert(CGPoint(x: 20, y: 18), to: nil)
        for commit in [false, true] {
            source.mouseDown(with: try event(.leftMouseDown, at: start, window: h.window))
            canvas.continuePanelDrag(try event(.leftMouseDragged, at: end, window: h.window))
            XCTAssertEqual(owner.dropIndicator, .inside(.folder(outer)))
            if commit { canvas.finishPanelDrag(try event(.leftMouseUp, at: end, window: h.window)) }
            else { canvas.cancelInteraction() }
            await h.layout()
            XCTAssertEqual(try ProjectNavigation.read(try XCTUnwrap(h.fixture.session.activeProject)).documentFolders[id], commit ? outer : inner)
        }
    }

    func testLegacyFolderNestingZonesRejectCyclesAndRootBackgroundExtracts() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let owner = try XCTUnwrap(try row(id, in: h).owner)
        let outer = try XCTUnwrap(owner.createFolder()), inner = try XCTUnwrap(owner.createFolder(in: outer))
        let other = try XCTUnwrap(owner.createFolder())
        await h.layout()
        let root = try XCTUnwrap(h.requests.spatialWorkspace?.canvas?.hosts[.navigator])
        func destination(_ source: UUID, _ target: UUID, _ y: CGFloat) throws -> ProjectNavigationDrop? {
            let row = try XCTUnwrap(h.element("purlory.navigator.drag.folder.\(target.uuidString)") as? NSView)
            return ProjectNavigatorController.destination(for: .folder(source),
                at: row.convert(CGPoint(x: 50, y: y), to: nil), in: root)?.1
        }
        XCTAssertEqual(try destination(other, outer, 33), .inside(.folder(outer)), "Expanded folder bottom leads into its children")
        XCTAssertNil(try destination(outer, inner, 17), "Cannot move an ancestor into its descendant")
        owner.toggle(outer); await h.layout()
        XCTAssertEqual(try destination(other, outer, 33), .after(.folder(outer)))
        owner.performDrop(.folder(other), destination: .inside(.folder(outer)), project: h.fixture.project.id, epoch: h.fixture.session.activationEpoch)
        await h.layout()
        XCTAssertEqual(owner.organization.parent(of: .folder(other)), outer)
        let last = try row(id, in: h)
        let blank = last.convert(CGPoint(x: 60, y: last.bounds.height + 25), to: nil)
        XCTAssertEqual(ProjectNavigatorController.destination(for: .folder(other), at: blank, in: root)?.1, .root)
        owner.performDrop(.folder(other), destination: .root, project: h.fixture.project.id, epoch: h.fixture.session.activationEpoch)
        XCTAssertNil(owner.organization.parent(of: .folder(other)))
    }

    func testDraggingNestedFolderOutPreservesItsSubtreeAndSupportsUndo() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let owner = try XCTUnwrap(try row(id, in: h).owner)
        let outer = try XCTUnwrap(owner.createFolder()), inner = try XCTUnwrap(owner.createFolder(in: outer))
        let child = try XCTUnwrap(owner.createFolder(in: inner))
        XCTAssertTrue(owner.perform(.drop(.document(id), .inside(.folder(child)))))
        await h.layout()
        let editor = try XCTUnwrap(h.requests.nativeEditor)
        let source = try XCTUnwrap(h.element("purlory.navigator.drag.folder.\(inner.uuidString)") as? ProjectNavigatorRowDragView)
        let start = source.convert(CGPoint(x: 60, y: 17), to: nil)
        let end = source.convert(CGPoint(x: 4, y: 17), to: nil)
        source.mouseDown(with: try event(.leftMouseDown, at: start, window: h.window))
        source.mouseDragged(with: try event(.leftMouseDragged, at: end, window: h.window))
        XCTAssertEqual(owner.dropIndicator, .root)
        source.mouseUp(with: try event(.leftMouseUp, at: end, window: h.window)); await h.layout()
        XCTAssertNil(owner.organization.parent(of: .folder(inner)))
        XCTAssertEqual(owner.organization.parent(of: .folder(child)), inner)
        XCTAssertEqual(owner.organization.documentFolders[id], child)
        XCTAssertTrue(h.requests.nativeEditor === editor)
        editor.undoManager?.undo(); await h.layout()
        XCTAssertEqual(owner.organization.parent(of: .folder(inner)), outer)
        XCTAssertEqual(owner.organization.documentFolders[id], child)
    }

    func testFolderBottomBoundaryMovesDocumentToItsEnclosingList() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let owner = try XCTUnwrap(try row(id, in: h).owner)
        let outer = try XCTUnwrap(owner.createFolder()), inner = try XCTUnwrap(owner.createFolder(in: outer))
        XCTAssertTrue(owner.perform(.drop(.document(id), .inside(.folder(inner)))))
        _ = h.fixture.session.createDocument(title: "Parent sibling", in: outer)
        await h.layout()
        let canvas = try XCTUnwrap(h.requests.spatialWorkspace?.canvas)
        for destination: ProjectNavigationDrop in [.inside(.folder(outer)), .root] {
            let boundary = try XCTUnwrap(h.elements().compactMap { $0 as? ProjectNavigatorRowDragView }
                .first { $0.backgroundDrop == destination })
            let source = try row(id, in: h)
            let start = source.convert(CGPoint(x: 50, y: 18), to: nil)
            let end = boundary.convert(CGPoint(x: 70, y: boundary.bounds.midY), to: nil)
            source.mouseDown(with: try event(.leftMouseDown, at: start, window: h.window))
            canvas.continuePanelDrag(try event(.leftMouseDragged, at: end, window: h.window))
            XCTAssertEqual(owner.dropIndicator, destination)
            canvas.finishPanelDrag(try event(.leftMouseUp, at: end, window: h.window)); await h.layout()
            XCTAssertEqual(owner.organization.documentFolders[id], destination == .root ? nil : outer)
        }
    }

    func testCollapsedFolderSpringOpensAndLeavingCancelsThePendingOpen() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let owner = try XCTUnwrap(try row(id, in: h).owner)
        let folder = try XCTUnwrap(owner.createFolder())
        owner.toggle(folder)
        owner.preview(.inside(.folder(folder)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while owner.collapsed.contains(folder), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(owner.collapsed.contains(folder))
        owner.preview(nil); owner.toggle(folder)
        owner.preview(.inside(.folder(folder))); owner.preview(nil)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(owner.collapsed.contains(folder))
    }
    private func event(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
