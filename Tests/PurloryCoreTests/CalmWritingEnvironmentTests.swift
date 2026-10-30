@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class CalmWritingEnvironmentTests: XCTestCase {
    func testSingleSheetTransitionKeepsTheNativeEditorAndSelection() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true)
        defer { h.close() }
        let editor = try await h.editor()
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        let canvas = try XCTUnwrap(model.canvas)
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let selection = editor.selectedRange()
        model.setLayout(SpatialWorkspaceLayout(documents: [id], selected: id, navigatorVisible: false))
        await h.layout()
        XCTAssertNotNil(h.element("purlory.binder.tab.\(id.rawValue.uuidString)"))
        XCTAssertEqual(canvas.hosts[.document(id)]?.layer?.cornerRadius, 0)
        XCTAssertTrue(h.requests.nativeEditor === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
        model.toggle(.navigator); await h.layout()
        XCTAssertNotNil(h.element("purlory.binder.tab.\(id.rawValue.uuidString)"))
        XCTAssertTrue(h.requests.nativeEditor === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
    }

    func testHoverDoesNotChangeFocusOpacityAndOptionExplicitlyRevealsTools() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("First paragraph\nSecond paragraph")
        let editor = try await h.editor()
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        let interaction = try XCTUnwrap(editor.workspaceInteraction as? WorkspaceEditorInteraction)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        model.focusDimming = true
        let offset = (editor.string as NSString).range(of: "Second").location
        let rect = try XCTUnwrap(interaction.paragraphRect(at: offset))
        let point = editor.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
            modifierFlags: [], timestamp: 1, windowNumber: h.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        var hoverCount = 0
        h.requests.workspaceHover = { _, _, _ in hoverCount += 1 }
        interaction.mouseMoved(event)
        XCTAssertFalse(interaction.optionHeld)
        XCTAssertEqual(hoverCount, 0)
        XCTAssertEqual(interaction.paragraphOpacity(at: offset), 0.24, accuracy: 0.001)
        model.noteTyping(at: h.window.convertPoint(toScreen: point))
        interaction.setOptionHeld(true)
        XCTAssertFalse(model.whisperTyping)
        XCTAssertGreaterThan(hoverCount, 0)
        XCTAssertEqual(interaction.paragraphOpacity(at: offset), 0.24, accuracy: 0.001)
        interaction.setOptionHeld(false)
        XCTAssertFalse(interaction.optionHeld)
        XCTAssertEqual(interaction.paragraphOpacity(at: 0), 1)
    }

    func testSingleManuscriptUsesTheWholeViewportButReferencePanelsRestoreGutters() throws {
        let id = WritingDocumentID()
        var layout = SpatialWorkspaceLayout(documents: [id], selected: id, navigatorVisible: false)
        let size = CGSize(width: 1000, height: 700)
        let single = SpatialWorkspaceGeometry(layout: layout, viewport: size)
        XCTAssertEqual(single.tiles[.document(id)], CGRect(origin: .zero, size: size))
        XCTAssertEqual(single.contentSize, size)
        layout.toggle(.characters)
        let multiple = SpatialWorkspaceGeometry(layout: layout, viewport: size)
        XCTAssertEqual(try XCTUnwrap(multiple.tiles[.document(id)]).minX, 8)
        XCTAssertEqual(try XCTUnwrap(multiple.tiles[.document(id)]).minY, 8)
    }

    func testTypographySeparatesParagraphsWithoutChangingManuscriptText() throws {
        let editor = BlockTextView(frame: .zero)
        editor.editorialWorkspaceStyle = true; editor.baseFontSize = 18.5
        editor.proseLayout = .continuous
        let continuous = editor.styleAttributes(for: .p, checked: false)
        let style = try XCTUnwrap(continuous[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(style.firstLineHeadIndent, 18.5)
        XCTAssertEqual(style.headIndent, 0)
        XCTAssertEqual(style.paragraphSpacing, 4)
        XCTAssertEqual(continuous[.kern] as? CGFloat, 0)
        editor.proseLayout = .spaced
        let spaced = try XCTUnwrap(editor.styleAttributes(for: .p, checked: false)[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(spaced.firstLineHeadIndent, 0)
        XCTAssertEqual(spaced.paragraphSpacing, 12)
        XCTAssertEqual(CompletionSettings.defaultLineSpacing, 11.5)
    }

    func testNormalPouchDragCannotHideWindowButExplicitOrbRemainsDraggable() throws {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pouch = WorkspacePouchController(model: SpatialWorkspaceController(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        pouch.reduceMotion = true; pouch.attach(to: window)
        defer { pouch.detach(); window.close() }
        pouch.beginDrag(at: CGPoint(x: 300, y: 500))
        pouch.updateDrag(to: CGPoint(x: 10, y: 10))
        XCTAssertFalse(pouch.isCollapsed); XCTAssertFalse(pouch.isDragging)
        pouch.collapse()
        XCTAssertTrue(pouch.isCollapsed)
        let panel = try XCTUnwrap(pouch.panel)
        let origin = panel.frame.origin
        pouch.beginDrag(at: CGPoint(x: origin.x + 22, y: origin.y + 22))
        pouch.updateDrag(to: CGPoint(x: origin.x + 122, y: origin.y + 22))
        XCTAssertTrue(pouch.isDragging)
    }
}
