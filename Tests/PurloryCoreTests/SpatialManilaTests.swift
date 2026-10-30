@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class SpatialManilaTests: XCTestCase {
    func testTabSwitchRetainsEditorSelectionScrollAndUndo() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody((0..<100).map { "Paragraph \($0) keeps its writing position." }.joined(separator: "\n"))
        let first = try await h.editor()
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let manager = try XCTUnwrap(first.undoManager)
        manager.beginUndoGrouping(); first.insertText("!", replacementRange: NSRange(location: 0, length: 0)); manager.endUndoGrouping()
        first.setSelectedRange(NSRange(location: 1500, length: 4))
        first.enclosingScrollView?.contentView.scroll(to: CGPoint(x: 0, y: 200))
        let scroll = try XCTUnwrap(first.enclosingScrollView?.contentView.bounds.origin)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second")); await h.layout()
        let second = try await h.editor()
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        let canvas = try XCTUnwrap(model.canvas)
        XCTAssertEqual(model.layout.columns.filter { $0.slots.contains { $0.tile.documentID != nil } }.count, 1)
        XCTAssertNotNil(canvas.hosts[.document(a)])
        XCTAssertTrue(canvas.hosts[.document(a)]?.isHidden == true)
        let frame = try XCTUnwrap(canvas.hosts[.document(b)]?.frame)
        model.open(a); await h.layout()
        let returned = try await h.editor()
        XCTAssertTrue(returned === first)
        XCTAssertTrue(returned.undoManager === manager)
        XCTAssertEqual(returned.selectedRange(), NSRange(location: 1500, length: 4))
        XCTAssertEqual(returned.enclosingScrollView?.contentView.bounds.origin.y ?? -1, scroll.y, accuracy: 0.5)
        XCTAssertEqual(canvas.hosts[.document(a)]?.frame, frame)
        model.open(b); await h.layout()
        let again = try await h.editor()
        XCTAssertTrue(again === second)
        XCTAssertTrue(model.close(.document(b))); await h.layout()
        XCTAssertEqual(h.fixture.session.selectedDocumentID, a)
        XCTAssertFalse(model.close(.document(a)))
        XCTAssertNotNil(model.toast)
    }

    func testTabControlsCreateSelectCloseAndQuietWithoutHidingActiveTab() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let plus = try XCTUnwrap(h.element("purlory.binder.new") as? NSButton)
        plus.performClick(nil); await h.layout()
        let b = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(model.layout.slot(containing: .document(b))?.tabs, [a, b])
        let activeHost = try XCTUnwrap(model.canvas?.hosts[.document(b)])
        let firstTab = try XCTUnwrap(find("purlory.binder.tab.\(a.rawValue.uuidString)", in: activeHost) as? NSButton)
        model.noteTyping(at: .zero); await h.layout()
        XCTAssertEqual(firstTab.alphaValue, 0.35, accuracy: 0.01)
        let activeTab = try XCTUnwrap(find("purlory.binder.tab.\(b.rawValue.uuidString)", in: activeHost) as? NSButton)
        XCTAssertEqual(activeTab.alphaValue, 1)
        firstTab.performClick(nil); await h.layout()
        XCTAssertEqual(h.fixture.session.selectedDocumentID, a)
        let current = try XCTUnwrap(model.canvas?.hosts[.document(a)])
        let close = try XCTUnwrap(find("purlory.binder.close.\(b.rawValue.uuidString)", in: current) as? NSButton)
        close.performClick(nil); await h.layout()
        XCTAssertEqual(model.layout.openDocuments, [a])
        XCTAssertNotNil(h.fixture.session.document(b), "Closing a tab must not trash its manuscript")
    }

    func testTabDragReordersTearsOffAndMergesWithRetainedHosts() async throws {
        let h = try await FramedWorkspaceHarness(width: 1200, reduceMotion: true); defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second")); await h.layout()
        let c = try XCTUnwrap(h.fixture.session.createDocument(title: "Third")); await h.layout()
        let model = try XCTUnwrap(h.requests.spatialWorkspace), canvas = try XCTUnwrap(model.canvas)
        model.open(a); await h.layout()
        let original = try XCTUnwrap(canvas.hosts[.document(a)])
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 1, windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func drag(_ id: WritingDocumentID, from start: CGPoint, to end: CGPoint) throws {
            canvas.beginPanelDrag(.document(id), event: try event(.leftMouseDown, start))
            canvas.continuePanelDrag(try event(.leftMouseDragged, end))
            canvas.finishPanelDrag(try event(.leftMouseUp, end))
        }
        let rect = try XCTUnwrap(canvas.geometry.tiles[.document(a)])
        try drag(a, from: CGPoint(x: rect.minX + 30, y: rect.minY + 16),
                 to: CGPoint(x: rect.maxX - 70, y: rect.minY + 16))
        await h.layout()
        XCTAssertEqual(model.layout.slot(containing: .document(a))?.tabs, [b, c, a])
        XCTAssertEqual(model.layout.columns.count, 2, "Reordering must not create a split")
        try drag(a, from: CGPoint(x: rect.minX + 250, y: rect.minY + 16),
                 to: CGPoint(x: rect.maxX - 60, y: rect.midY))
        await h.layout()
        XCTAssertEqual(model.layout.columns.count, 3)
        XCTAssertEqual(model.layout.slot(containing: .document(a))?.tabs, [a])
        let destination = try XCTUnwrap(canvas.geometry.tiles[model.layout.slot(containing: .document(b))!.tile])
        let source = try XCTUnwrap(canvas.geometry.tiles[.document(a)])
        try drag(a, from: CGPoint(x: source.minX + 30, y: source.minY + 16),
                 to: CGPoint(x: destination.minX + 20, y: destination.minY + 16))
        await h.layout()
        XCTAssertEqual(model.layout.columns.count, 2)
        XCTAssertEqual(model.layout.slot(containing: .document(a))?.tabs, [a, b, c])
        XCTAssertTrue(canvas.hosts[.document(a)] === original)
        XCTAssertEqual(Set(model.layout.openDocuments), [a, b, c])
    }

    func testFirstRevealOfHiddenTabKeepsTheBinderFrameWithMotionEnabled() async throws {
        let h = try await SourceNavigationHarness(); defer { h.close() }
        let model = try XCTUnwrap(h.requests.spatialWorkspace), canvas = try XCTUnwrap(model.canvas)
        canvas.reduceMotion = false
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(model.layout.openDocuments.first { $0 != a })
        let frame = try XCTUnwrap(canvas.geometry.tiles[.document(a)])
        model.open(b); await h.layout()
        XCTAssertEqual(canvas.hosts[.document(b)]?.frame, frame,
            "A tab switch must not animate a previously hidden editor from a zero-size frame")
    }

    func testNativeTabDragMergesOverInactiveLabelAfterSpatialPreview() async throws {
        let h = try await FramedWorkspaceHarness(width: 1400, reduceMotion: true); defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second")); await h.layout()
        let c = try XCTUnwrap(h.fixture.session.createDocument(title: "Third")); await h.layout()
        let model = try XCTUnwrap(h.requests.spatialWorkspace), canvas = try XCTUnwrap(model.canvas)
        var split = model.layout; split.move(.document(c), to: .end); model.setLayout(split)
        model.open(a); await h.layout()
        let originalHost = try XCTUnwrap(canvas.hosts[.document(c)])
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 1, windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let source = try XCTUnwrap(find("purlory.binder.tab.\(c.rawValue.uuidString)", in: originalHost) as? SpatialManilaTabButton)
        source.mouseDown(with: try event(.leftMouseDown, canvas.convert(CGPoint(x: 35, y: 16), from: source)))
        let body = try XCTUnwrap(canvas.geometry.tiles[.document(a)])
        canvas.continuePanelDrag(try event(.leftMouseDragged, CGPoint(x: body.minX + 30, y: body.midY)))
        await h.layout()
        XCTAssertTrue(model.isDragging)
        let destination = try XCTUnwrap(canvas.hosts[.document(a)])
        let label = try XCTUnwrap(find("purlory.binder.tab.\(b.rawValue.uuidString)", in: destination))
        let point = canvas.convert(CGPoint(x: label.bounds.midX - 10, y: 16), from: label)
        canvas.continuePanelDrag(try event(.leftMouseDragged, point)); await h.layout()
        XCTAssertTrue(model.isTabDrop)
        canvas.finishPanelDrag(try event(.leftMouseUp, point)); await h.layout()
        XCTAssertEqual(model.layout.slot(containing: .document(a))?.tabs, [a, c, b])
        XCTAssertEqual(model.layout.columns.count, 2)
        XCTAssertEqual(h.fixture.session.selectedDocumentID, c)
        XCTAssertTrue(canvas.hosts[.document(c)] === originalHost)
    }

    func testDraggingTabToDocumentListClosesOnlyItsPresentationAndCanBeCancelled() async throws {
        let h = try await FramedWorkspaceHarness(width: 1200, reduceMotion: true); defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Return to list")); await h.layout()
        h.fixture.session.updateSelectedDocumentBody("Keep this manuscript intact.")
        let model = try XCTUnwrap(h.requests.spatialWorkspace), canvas = try XCTUnwrap(model.canvas)
        var split = model.layout; split.move(.document(b), to: .end); model.setLayout(split); await h.layout()
        let original = model.layout
        let documents = try XCTUnwrap(h.fixture.session.activeProject).documents
        var reorderCount = 0
        model.onTileReorder = { _ in reorderCount += 1 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 1, windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func begin(_ id: WritingDocumentID) throws {
            let host = try XCTUnwrap(canvas.hosts[.document(id)])
            let tab = try XCTUnwrap(find("purlory.binder.tab.\(id.rawValue.uuidString)", in: host) as? SpatialManilaTabButton)
            let point = canvas.convert(CGPoint(x: 35, y: 16), from: tab)
            tab.mouseDown(with: try event(.leftMouseDown, point))
        }
        let list = try XCTUnwrap(canvas.geometry.tiles[.navigator])
        let destination = CGPoint(x: list.midX, y: list.maxY - 40)
        try begin(b)
        canvas.continuePanelDrag(try event(.leftMouseDragged, destination))
        XCTAssertEqual(model.presentationLayout, original, "A list return must not open a spatial insertion gap")
        canvas.cancelInteraction(); await h.layout()
        XCTAssertEqual(model.layout, original)

        try begin(b)
        canvas.continuePanelDrag(try event(.leftMouseDragged, destination))
        canvas.finishPanelDrag(try event(.leftMouseUp, destination)); await h.layout()
        XCTAssertFalse(model.layout.contains(.document(b)))
        XCTAssertEqual(model.layout.columns.count, original.columns.count - 1)
        XCTAssertEqual(h.fixture.session.selectedDocumentID, a)
        XCTAssertEqual(h.fixture.session.activeProject?.documents, documents)
        XCTAssertFalse(h.fixture.session.activeProject?.trashedDocumentIDs.contains(b) ?? true)
        XCTAssertEqual(reorderCount, 0, "Returning to the list must not change manuscript order")

        model.open(b); await h.layout()
        XCTAssertEqual(model.layout.slot(containing: .document(a))?.tabs, [a, b])
        XCTAssertEqual(h.fixture.session.document(b)?.body, "Keep this manuscript intact.")
        XCTAssertTrue(model.close(.document(b))); await h.layout()
        // Remove any other initially opened fixture documents, keeping the last-tab guard explicit.
        for id in model.layout.openDocuments where id != a { _ = model.close(.document(id)) }
        await h.layout()
        try begin(a)
        canvas.continuePanelDrag(try event(.leftMouseDragged, destination))
        canvas.finishPanelDrag(try event(.leftMouseUp, destination)); await h.layout()
        XCTAssertEqual(model.layout.openDocuments, [a])
        XCTAssertNotNil(model.toast)
    }

    func testNarrowStripScrollsSelectedTabIntoViewAndMiddleClickClosesIt() throws {
        for theme in [PurloryTheme.light, .dark] {
            let bar = SpatialManilaTabBarView(frame: CGRect(x: 0, y: 0, width: 320, height: 34))
            let documents = (1...8).map { WritingDocument(id: WritingDocumentID(), title: "\($0)화. 바람이 머무는 자리", body: "", kind: .manuscript) }
            var closed: WritingDocumentID?
            bar.configure(documents: documents, active: documents[7].id, theme: theme, quiet: false,
                typewriter: false, focus: false, canCreate: true, activate: { _ in }, close: { closed = $0 },
                create: {}, toggleTypewriter: {}, toggleFocus: {})
            bar.layoutSubtreeIfNeeded()
            let tab = try XCTUnwrap(bar.tabs.last)
            XCTAssertGreaterThan(tab.visibleRect.width, 90)
            let plus = try XCTUnwrap(find("purlory.binder.new", in: bar))
            XCTAssertGreaterThan(plus.frame.minX, tab.frame.maxX)
            let focus = try XCTUnwrap(find("purlory.binder.focus", in: bar))
            XCTAssertTrue(bar.bounds.contains(focus.frame))
            let cgEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
            tab.otherMouseUp(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
            XCTAssertEqual(closed, documents[7].id)
            if let directory = ProcessInfo.processInfo.environment["PURLORY_MANILA_CAPTURE_DIR"] {
                let bitmap = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
                bar.cacheDisplay(in: bar.bounds, to: bitmap)
                let name = theme == .light ? "light" : "dark"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/manila-\(name).png"))
                bar.frame.size.width = 740
                bar.configure(documents: Array(documents.prefix(3)), active: documents[2].id, theme: theme, quiet: false,
                    typewriter: false, focus: false, canCreate: true, activate: { _ in }, close: { _ in },
                    create: {}, toggleTypewriter: {}, toggleFocus: {})
                bar.layoutSubtreeIfNeeded()
                let wide = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
                bar.cacheDisplay(in: bar.bounds, to: wide)
                try XCTUnwrap(wide.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/tabs-\(name).png"))
            }
        }
    }

    private func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
}
