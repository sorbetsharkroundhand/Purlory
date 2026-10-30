@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class SpatialNativeWorkspaceTests: XCTestCase {
    func testCanvasAndPouchExposeNamedNativeAccessibilityGroups() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let canvas = try XCTUnwrap(descendant(h.host, SpatialWorkspaceCanvasView.self))
        XCTAssertTrue(canvas.isAccessibilityElement())
        XCTAssertEqual(canvas.accessibilityRole(), .group)
        XCTAssertEqual(canvas.accessibilityIdentifier(), "purlory.workspace.tiles")
        let trigger = try XCTUnwrap(h.requests.spatialWorkspace?.pouchAnchor)
        XCTAssertEqual(trigger.accessibilityRole(), .button)
        XCTAssertEqual(trigger.accessibilityIdentifier(), "purlory.writer-tools.compatibility")
    }
    func testFirstGripPressInAnInitiallyInactiveTileActivatesAndStartsTheDrag() async throws {
        let h = try await SourceNavigationHarness(); defer { h.close() }
        let b = try XCTUnwrap(h.fixture.session.activeProject?.documents.last?.id)
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        var split = model.layout; split.move(.document(b), to: .end); model.setLayout(split); await h.layout()
        let key = ProjectDocumentKey(projectID: h.fixture.project.id, documentID: b)
        let editor = try XCTUnwrap(h.requests.editor(for: key))
        XCTAssertNotEqual(h.fixture.session.selectedDocumentID, b)
        let interaction = try XCTUnwrap(editor.workspaceInteraction as? WorkspaceEditorInteraction)
        let grip = try XCTUnwrap(interaction.paragraphGrip(at: 0))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(CGPoint(x: grip.midX, y: grip.midY), to: nil), modifierFlags: [.option], timestamp: 1,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(interaction.mouseDown(event))
        XCTAssertEqual(h.fixture.session.selectedDocumentID, b)
        interaction.detach()
    }
    func testQueuedResizeFromPreviousProjectCannotRestoreItsTiles() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true); defer { h.close() }
        let canvas = try XCTUnwrap(descendant(h.host, SpatialWorkspaceCanvasView.self))
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 200), modifierFlags: [], timestamp: 1,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        canvas.beginResize(.column(0), event: try event(.leftMouseDown, 210))
        let id = WritingDocumentID()
        let next = WritingProject(id: WritingProjectID(), title: "Next", mode: .general,
            documents: [.init(id: id, title: "Next", body: "Only next project", kind: .manuscript)])
        try await h.fixture.session.saveAndActivate(next); await h.layout()
        canvas.continueResize(try event(.leftMouseDragged, 260)); canvas.finishResize(); await h.layout()
        XCTAssertEqual(h.requests.spatialWorkspace?.layout.openDocuments, [id])
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, "Only next project")
    }
    func testAccessibilityIdentifiesOnlyTheSelectedEditorAsTheCommandTarget() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let first = try await h.editor()
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second"))
        await h.layout()
        let second = try await h.editor()
        XCTAssertEqual(second.accessibilityIdentifier(), "purlory.editor")
        XCTAssertNotEqual(first.accessibilityIdentifier(), "purlory.editor")
        let selectedTile = h.requests.spatialWorkspace?.selectedTile
        h.requests.spatialWorkspace?.openPouchTools(); await h.layout()
        XCTAssertEqual(h.requests.spatialWorkspace?.selectedTile, selectedTile)
        XCTAssertEqual(h.fixture.session.selectedDocumentID, b)
        XCTAssertTrue(h.requests.nativeEditor === second)
    }
    func testParagraphGripMovesRichSourceAcrossLiveEditorsAndUndoesBoth() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let original = "First\n**이동🙂** $x$\n\n![](images/a.png)\nLast\n"
        h.fixture.session.updateSelectedDocumentBody(original)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Paragraph target"))
        h.fixture.session.updateSelectedDocumentBody("> Target\n"); await h.layout()
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        var split = model.layout; split.move(.document(b), to: .after(.document(a))); model.setLayout(split); await h.layout()
        let source = try XCTUnwrap(allEditors(h.host).first { $0.writingDocumentIdentity?.documentID == a })
        let target = try XCTUnwrap(allEditors(h.host).first { $0.writingDocumentIdentity?.documentID == b })
        let interaction = try XCTUnwrap(source.workspaceInteraction as? WorkspaceEditorInteraction)
        let targetInteraction = try XCTUnwrap(target.workspaceInteraction as? WorkspaceEditorInteraction)
        let offset = (source.string as NSString).range(of: "이동🙂").location
        let grip = try XCTUnwrap(interaction.paragraphGrip(at: offset))
        let targetRect = try XCTUnwrap(targetInteraction.paragraphRect(at: 0))
        func event(_ type: NSEvent.EventType, view: NSView, point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [.option],
                timestamp: 1, windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        source.mouseMoved(with: try event(.mouseMoved, view: source, point: CGPoint(x: grip.midX, y: grip.midY)))
        let press = try event(.leftMouseDown, view: source, point: CGPoint(x: grip.midX, y: grip.midY))
        let handled = interaction.mouseDown(press)
        XCTAssertTrue(handled, "The paragraph gutter must hit the paragraph at its Y coordinate")
        guard handled else { return }
        source.mouseDown(with: press)
        source.mouseDragged(with: try event(.leftMouseDragged, view: target, point: CGPoint(x: targetRect.midX, y: targetRect.minY + 1)))
        source.mouseUp(with: try event(.leftMouseUp, view: target, point: CGPoint(x: targetRect.midX, y: targetRect.minY + 1)))
        await h.layout()
        XCTAssertEqual(h.fixture.session.document(a)?.body, "First\n\n![](images/a.png)\nLast\n")
        XCTAssertEqual(h.fixture.session.document(b)?.body, "**이동🙂** $x$\n> Target\n")
        target.undoManager?.undo(); await h.layout()
        XCTAssertEqual(h.fixture.session.document(a)?.body, original)
        XCTAssertEqual(h.fixture.session.document(b)?.body, "> Target\n")
        XCTAssertEqual(source.serialize(), original)
    }

    func testTypewriterAndFocusArePresentationOnly() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("First paragraph\nSecond paragraph\nThird paragraph")
        await h.layout()
        let editor = try await h.editor()
        let interaction = try XCTUnwrap(editor.workspaceInteraction as? WorkspaceEditorInteraction)
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        let before = editor.serialize()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        model.typewriter = true; model.focusDimming = true; await h.layout()
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(scroll.contentInsets.top, scroll.bounds.height * 0.26, accuracy: 1)
        XCTAssertEqual(scroll.contentInsets.bottom, scroll.bounds.height * 0.38, accuracy: 1)
        XCTAssertEqual(interaction.paragraphOpacity(at: 0), 1)
        XCTAssertEqual(interaction.paragraphOpacity(at: 17), 0.24, accuracy: 0.001)
        XCTAssertEqual(editor.serialize(), before)
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, before)
    }

    func testParagraphDamageIncludesItsGripWithoutInvalidatingTheWholeEditor() async throws {
        let h = try await FramedWorkspaceHarness(width: 1100, reduceMotion: true)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("First paragraph\nSecond paragraph\nThird paragraph")
        await h.layout()
        let editor = try await h.editor()
        let interaction = try XCTUnwrap(editor.workspaceInteraction as? WorkspaceEditorInteraction)
        let offset = (editor.string as NSString).range(of: "Second").location
        let damage = try XCTUnwrap(interaction.paragraphDamage(at: offset))
        let grip = try XCTUnwrap(interaction.paragraphGrip(at: offset))
        XCTAssertGreaterThanOrEqual(grip.width, 28)
        XCTAssertTrue(damage.contains(grip.intersection(editor.visibleRect)))
        XCTAssertTrue(editor.visibleRect.contains(damage))
        XCTAssertLessThan(damage.height, editor.visibleRect.height)
        XCTAssertFalse(damage.intersects(try XCTUnwrap(interaction.paragraphRect(at: 0)).insetBy(dx: 0, dy: 5)))
    }

    func testNavigatorNativeDragReordersWithoutReplacingOrClosingEditors() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Move before first"))
        await h.layout()
        let before = allEditors(h.host)
        let source = try XCTUnwrap(h.element("purlory.navigator.drag.\(b.rawValue.uuidString)") as? NSView)
        let target = try XCTUnwrap(h.element("purlory.navigator.drag.\(a.rawValue.uuidString)") as? NSView)
        func event(_ type: NSEvent.EventType, location: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        source.mouseDown(with: try event(.leftMouseDown, location: source.convert(CGPoint(x: 50, y: source.bounds.midY), to: nil)))
        source.mouseDragged(with: try event(.leftMouseDragged, location: target.convert(CGPoint(x: 50, y: 1), to: nil)))
        source.mouseUp(with: try event(.leftMouseUp, location: target.convert(CGPoint(x: 50, y: 1), to: nil)))
        await h.layout()
        XCTAssertEqual(h.fixture.session.activeProject?.documents.map(\.id), [b, a])
        XCTAssertEqual(allEditors(h.host).count, 2)
        for editor in before { XCTAssertTrue(allEditors(h.host).contains { $0 === editor }) }
    }

    func testNativeDividersResizeColumnsAndAdjacentRows() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Lower"))
        await h.layout()
        let canvas = try XCTUnwrap(descendant(h.host, SpatialWorkspaceCanvasView.self))
        let model = try XCTUnwrap(canvas.model)
        var stacked = model.layout; stacked.move(.document(b), to: .below(.document(a)))
        model.setLayout(stacked); await h.layout()
        let column = try XCTUnwrap(h.element("purlory.tile.column-resize.0") as? NSView)
        func event(_ type: NSEvent.EventType, _ view: NSView, _ offset: CGPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(offset, to: nil), modifierFlags: [],
                timestamp: 1, windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
        }
        column.mouseDown(with: try event(.leftMouseDown, column, .zero))
        column.mouseDragged(with: try event(.leftMouseDragged, column, CGPoint(x: 80, y: 0)))
        column.mouseUp(with: try event(.leftMouseUp, column, .zero)); await h.layout()
        XCTAssertEqual(model.layout.columns[0].width, 284)
        let row = try XCTUnwrap(h.element("purlory.tile.row-resize.1.0") as? NSView)
        row.mouseDown(with: try event(.leftMouseDown, row, .zero))
        row.mouseDragged(with: try event(.leftMouseDragged, row, CGPoint(x: 0, y: 10_000)))
        row.mouseUp(with: try event(.leftMouseUp, row, .zero)); await h.layout()
        XCTAssertEqual(model.layout.columns[1].slots[0].weight, 0.8, accuracy: 0.001)
        row.mouseDown(with: try event(.leftMouseDown, row, .zero, clicks: 2)); await h.layout()
        XCTAssertEqual(model.layout.columns[1].slots.map(\.weight), [0.5, 0.5])
    }

    func testNativeHeaderDragStacksTilesAndEscapeRestoresExactOrigin() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Target"))
        await h.layout()
        let canvas = try XCTUnwrap(descendant(h.host, SpatialWorkspaceCanvasView.self))
        let model = try XCTUnwrap(canvas.model)
        var split = model.layout; split.move(.document(b), to: .after(.document(a))); model.setLayout(split)
        model.open(a); await h.layout()
        let header = try XCTUnwrap(h.element("purlory.binder.tab.\(a.rawValue.uuidString)") as? NSView)
        let source = try XCTUnwrap(canvas.geometry.tiles[.document(a)])
        let destination = try XCTUnwrap(canvas.geometry.tiles[.document(b)])
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: 1, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let origin = model.layout
        header.mouseDown(with: try event(.leftMouseDown, CGPoint(x: source.midX, y: source.minY + 12)))
        header.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: destination.midX, y: destination.minY + 45)))
        XCTAssertTrue(model.isDragging)
        XCTAssertEqual(model.previewTarget, .above(.document(b)))
        header.cancelOperation(nil)
        XCTAssertEqual(model.layout, origin)
        header.mouseDown(with: try event(.leftMouseDown, CGPoint(x: source.midX, y: source.minY + 12)))
        header.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: destination.midX, y: destination.minY + 45)))
        header.mouseUp(with: try event(.leftMouseUp, CGPoint(x: destination.midX, y: destination.minY + 45)))
        await h.layout()
        XCTAssertEqual(model.layout.columns.last?.slots.map(\.tile), [.document(a), .document(b)])
        XCTAssertEqual(allEditors(h.host).count, 2)
    }

    func testMultipleLiveEditorsKeepIndependentUndoAndCompositionWhileTilesMove() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Second live tile"))
        await h.layout()
        let workspace = try XCTUnwrap(h.requests.spatialWorkspace)
        var split = workspace.layout; split.move(.document(b), to: .after(.document(a))); workspace.setLayout(split); await h.layout()
        let editors = allEditors(h.host)
        XCTAssertEqual(editors.count, 2, "The executable HTML requires simultaneous native editors")
        let aEditor = try XCTUnwrap(editors.first { $0.writingDocumentIdentity?.documentID == a })
        let bEditor = try XCTUnwrap(editors.first { $0.writingDocumentIdentity?.documentID == b })
        XCTAssertFalse(aEditor === bEditor)
        XCTAssertFalse(aEditor.undoManager === bEditor.undoManager)
        h.window.makeFirstResponder(bEditor)
        bEditor.insertText("Second body", replacementRange: NSRange(location: 0, length: 0))
        h.window.makeFirstResponder(aEditor)
        aEditor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        let before = aEditor.string, selection = aEditor.selectedRange()
        let canvas = try XCTUnwrap(descendant(h.host, SpatialWorkspaceCanvasView.self))
        let model = try XCTUnwrap(canvas.model)
        var moved = model.layout
        moved.move(.document(a), to: .above(.document(b)))
        model.setLayout(moved); await h.layout()
        h.window.setContentSize(CGSize(width: 900, height: 650)); await h.layout()
        XCTAssertTrue(allEditors(h.host).contains { $0 === aEditor })
        XCTAssertTrue(aEditor.hasMarkedText()); XCTAssertEqual(aEditor.string, before)
        XCTAssertEqual(aEditor.selectedRange(), selection)
        XCTAssertTrue(h.window.firstResponder === aEditor)
        XCTAssertEqual(h.fixture.session.document(b)?.body, "Second body")
        aEditor.unmarkText(); aEditor.didChangeText()
    }

    private func allEditors(_ root: NSView) -> [BlockTextView] {
        (root as? BlockTextView).map { [$0] } ?? root.subviews.flatMap(allEditors)
    }
    private func descendant<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
        (root as? T) ?? root.subviews.compactMap { descendant($0, type) }.first
    }
}
