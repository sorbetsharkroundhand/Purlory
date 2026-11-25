import AppKit
import XCTest
@testable import PurloryWorkspaceUI

@MainActor final class WorkspacePouchIndexTests: XCTestCase {
    func testIndexBridgesTheRoundedWindowCornerWithoutCoveringTheWindow() {
        let window = CGRect(x: 100, y: 150, width: 1000, height: 700)
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        for progress in [CGFloat(0), 0.5, 1] {
            let geometry = WorkspacePouchIndexGeometry(window: window, screen: screen, progress: progress, hover: 0)
            let join = window.maxX - geometry.frame.minX
            XCTAssertEqual(join, 18, "The panel must include the window's rounded corner cutout")
            XCTAssertTrue(geometry.path.contains(CGPoint(x: join - 3, y: 2)), "The top corner must not leave a desktop-colored notch")
            XCTAssertFalse(geometry.path.contains(CGPoint(x: join - 3, y: 40)), "The material must not double over the window")
            XCTAssertEqual(geometry.frame.maxY, window.maxY)
            XCTAssertEqual(geometry.materialFrame.height, window.height)
            XCTAssertEqual(geometry.materialFrame.maxX, geometry.frame.width)
        }
    }

    func testIndexUsesTheSameNativeGlassAsTheWindow() throws {
        let view = WorkspacePouchIndexView(frame: CGRect(x: 0, y: 0, width: 38, height: 94))
        view.configure(theme: .dark, actions: [])
        let material = try XCTUnwrap(view.subviews.first { $0 is WorkspaceLiquidGlass.Surface })
        let reference = WorkspaceLiquidGlass.Surface()
        reference.configure(theme: .dark, opaque: false)
        if #available(macOS 26.0, *) {
            let actual = try XCTUnwrap(material.subviews.first as? NSGlassEffectView)
            let expected = try XCTUnwrap(reference.subviews.first as? NSGlassEffectView)
            XCTAssertEqual(actual.style, expected.style)
            XCTAssertEqual(actual.tintColor, expected.tintColor)
        } else {
            let actual = try XCTUnwrap(material.subviews.first as? NSVisualEffectView)
            let expected = try XCTUnwrap(reference.subviews.first as? NSVisualEffectView)
            XCTAssertEqual(actual.material, expected.material)
            XCTAssertEqual(actual.blendingMode, expected.blendingMode)
        }
        view.configure(theme: .dark, actions: [], reduceTransparency: true)
        XCTAssertTrue(try XCTUnwrap(material.subviews.first).isHidden)
        XCTAssertEqual(material.layer?.backgroundColor, PurloryTheme.dark.workspaceSurface.cgColor)
        view.configure(theme: .dark, actions: [])
        XCTAssertFalse(try XCTUnwrap(material.subviews.first).isHidden)
    }

    func testVisibleWorkspaceHasTopAlignedNonactivatingIndex() async throws {
        let h = try await FramedWorkspaceHarness(width: 860, reduceMotion: true)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        await h.layout()
        h.requests.pouch?.syncAttachment()
        let index = try XCTUnwrap(h.window.childWindows?.first {
            $0.contentView?.accessibilityIdentifier() == "purlory.workspace.pouch.index"
        })
        XCTAssertTrue(index.isVisible)
        XCTAssertFalse(index.canBecomeKey)
        XCTAssertEqual(index.frame.maxY, h.window.frame.maxY, accuracy: 0.5)
    }

    func testHoverTranslatesSurfaceAndScreenEdgeOpensInward() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let window = CGRect(x: 100, y: 150, width: 1000, height: 700)
        let closed = WorkspacePouchIndexGeometry(window: window, screen: screen, progress: 0, hover: 0)
        let hover = WorkspacePouchIndexGeometry(window: window, screen: screen, progress: 0, hover: 1)
        XCTAssertEqual(closed.exposedWidth, 20)
        XCTAssertEqual(hover.surfaceWidth, closed.surfaceWidth)
        XCTAssertEqual(hover.height, closed.height)
        XCTAssertEqual(hover.slide, 6)
        XCTAssertEqual(hover.frame.maxX - closed.frame.maxX, 6)
        let edgeWindow = CGRect(x: 590, y: 150, width: 1000, height: 700)
        for progress in [CGFloat(0), 0.5, 1] {
            let edge = WorkspacePouchIndexGeometry(window: edgeWindow, screen: screen, progress: progress, hover: 0)
            XCTAssertTrue(edge.opensInward)
            XCTAssertTrue(screen.contains(edge.frame))
            XCTAssertEqual(edge.frame.maxX, edgeWindow.maxX, "At the display edge, the rail must expand consistently inward")
            XCTAssertEqual(edge.frame.maxY, edgeWindow.maxY)
        }
    }

    func testDragUsesScreenCoordinatesAndReducedMotionSettlesImmediately() throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let index = WorkspacePouchIndexController(parent: window)
        defer { index.detach(); window.close() }
        index.reduceMotion = true; index.layout()
        let direction: CGFloat = index.geometry?.opensInward == true ? -1 : 1
        index.beginDrag(at: 100); index.updateDrag(to: 100 + 40 * direction)
        XCTAssertGreaterThan(try XCTUnwrap(index.geometry).exposedWidth, 20)
        XCTAssertLessThan(try XCTUnwrap(index.geometry).exposedWidth, 84)
        index.endDrag(at: 100 + 40 * direction)
        XCTAssertTrue(index.isExpanded)
        XCTAssertEqual(index.geometry?.exposedWidth, 84)
        index.beginDrag(at: 200); index.endDrag(at: 200 - 48 * direction)
        XCTAssertFalse(index.isExpanded)
        XCTAssertEqual(index.geometry?.exposedWidth, 20)
        index.setHovered(true)
        XCTAssertEqual(index.geometry?.slide, 0)
    }

    func testInterruptedExpansionContinuesFromItsVisiblePosition() throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let index = WorkspacePouchIndexController(parent: window)
        defer { index.detach(); window.close() }
        var time = 0.0
        index.animationTime = { time }
        index.setExpanded(true)
        time = 0.07; index.stepAnimation()
        let intermediate = try XCTUnwrap(index.geometry).frame
        XCTAssertGreaterThan(try XCTUnwrap(index.geometry).exposedWidth, 20)
        XCTAssertLessThan(try XCTUnwrap(index.geometry).exposedWidth, 84)
        index.setExpanded(false)
        XCTAssertEqual(index.geometry?.frame, intermediate)
        time = 1; index.stepAnimation()
        XCTAssertEqual(index.geometry?.exposedWidth, 20)
    }

    func testHiddenOrReducedMotionIndexCannotStayHalfExpanded() throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let index = WorkspacePouchIndexController(parent: window)
        defer { index.detach(); window.close() }
        var time = 0.0
        index.animationTime = { time }
        window.orderFront(nil); index.setExpanded(true)
        time = 0.06; index.stepAnimation()
        index.update(theme: .light, actions: [], visible: false)
        index.update(theme: .light, actions: [], visible: true)
        XCTAssertEqual(index.geometry?.exposedWidth, 84)
        XCTAssertTrue(index.panel.parent === window)
        index.setExpanded(false); time = 0.1; index.stepAnimation()
        index.reduceMotion = true
        index.update(theme: .light, actions: [], visible: true)
        XCTAssertEqual(index.geometry?.exposedWidth, 20)
    }

    func testScreenEdgeDetailCardDoesNotSitUnderTheIndex() async throws {
        let h = try await FramedWorkspaceHarness(width: 860, reduceMotion: true)
        defer { h.close() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        h.window.setFrameOrigin(CGPoint(x: screen.maxX - h.window.frame.width, y: screen.minY + 40))
        h.window.makeKeyAndOrderFront(nil); await h.layout()
        let pouch = try XCTUnwrap(h.requests.pouch)
        pouch.showTools(.overview); await h.layout()
        let index = try XCTUnwrap(pouch.index), canvas = try XCTUnwrap(h.requests.spatialWorkspace?.canvas)
        XCTAssertTrue(try XCTUnwrap(index.geometry).opensInward)
        let placement = try XCTUnwrap(canvas.pouchPlacement())
        let card = placement.card.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY)
        let screenCard = h.window.convertToScreen(canvas.convert(card, to: nil))
        XCTAssertLessThan(screenCard.maxX, index.panel.frame.minX)
        let geometry = try XCTUnwrap(index.geometry)
        let tailY = geometry.height - geometry.tail * 0.25
        XCTAssertTrue(geometry.path.contains(CGPoint(x: geometry.frame.width - 1, y: tailY)), "The inward taper must approach the window's right edge")
        XCTAssertFalse(geometry.path.contains(CGPoint(x: 1, y: tailY)))
    }

    func testIndexActionsPreserveEditorCompositionAndWindowLifecycle() async throws {
        let h = try await FramedWorkspaceHarness(width: 860, reduceMotion: true)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil); await h.layout()
        let editor = try await h.editor(), pouch = try XCTUnwrap(h.requests.pouch)
        let index = try XCTUnwrap(pouch.index), spatial = try XCTUnwrap(h.requests.spatialWorkspace)
        h.window.makeFirstResponder(editor)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        defer { while undo.groupingLevel > 0 { undo.endUndoGrouping() } }
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let selection = editor.selectedRange(), text = editor.string
        let tiles = spatial.canvas?.geometry.tiles
        let grip = try XCTUnwrap(h.element("purlory.writer-tools.compatibility") as? NSButton)
        XCTAssertNotNil(grip.image, "The concealed tab must have a visible grip")
        grip.performClick(nil)
        await h.layout()
        XCTAssertTrue(index.isExpanded); XCTAssertNil(spatial.pouchSection)
        XCTAssertEqual(spatial.canvas?.geometry.tiles, tiles)
        for id in ["note", "environment"] {
            try XCTUnwrap(h.element("purlory.workspace.pouch.index.\(id)") as? NSButton).performClick(nil)
            await h.layout()
            XCTAssertTrue(h.window.firstResponder === editor)
            XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(editor.undoManager === undo)
        }
        XCTAssertEqual(spatial.pouchSection, .overview)
        XCTAssertNotNil(h.element("purlory.workspace.pouch.more"))
        for id in ["note", "documents", "characters", "search", "history", "environment"] {
            let button = try XCTUnwrap(h.element("purlory.workspace.pouch.index.\(id)") as? NSButton)
            XCTAssertNotNil(button.image, "Every icon-only action needs its visible symbol: \(id)")
            XCTAssertEqual(button.bounds.size, CGSize(width: 44, height: 44))
        }
        pouch.collapse()
        XCTAssertFalse(index.panel.isVisible)
        pouch.restore(); await h.layout()
        XCTAssertTrue(index.panel.isVisible)
        XCTAssertFalse(index.isExpanded)
        pouch.detach()
        XCTAssertFalse(index.panel.isVisible); XCTAssertNil(index.panel.parent)
        editor.unmarkText()
    }

    func testCaptureNativeIndex() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PURLORY_INDEX_CAPTURE_DIR"] else { throw XCTSkip("Native capture is opt-in") }
        let customPalette = PaletteSettings.shared.enabled
        PaletteSettings.shared.enabled = false
        defer { PaletteSettings.shared.enabled = customPalette }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let h = try await FramedWorkspaceHarness(width: 1000, appearance: dark ? .dark : .light,
                                                     reduceMotion: true, projectTitle: "주머니 디자인 · 예시 원고", mode: .fiction)
            defer { h.close() }
            h.fixture.session.updateSelectedDocumentBody("# 오후의 기록\n\n창문을 열자 오래된 종이 냄새가 바람을 따라 들어왔다.\n\n그는 책갈피를 꺼내 마지막으로 읽던 페이지에 올려두었다. 생각은 잠시 주머니에 넣어 두어도 괜찮았다.")
            h.window.setFrameOrigin(CGPoint(x: 80, y: 80))
            h.window.styleMask.insert(.fullSizeContentView)
            h.window.titleVisibility = .hidden
            h.window.makeKeyAndOrderFront(nil); await h.layout()
            let backdropFrame = CGRect(x: h.window.frame.minX - 40, y: h.window.frame.minY - 40,
                width: h.window.frame.width + 160, height: h.window.frame.height + 80)
            let backdrop = NSWindow(contentRect: backdropFrame,
                styleMask: [.borderless], backing: .buffered, defer: false)
            backdrop.isReleasedWhenClosed = false
            backdrop.backgroundColor = NSColor(srgbRed: 0.98, green: 0.84, blue: 0.16, alpha: 1)
            backdrop.orderFrontRegardless()
            h.window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            defer { backdrop.close() }
            let pouch = try XCTUnwrap(h.requests.pouch), index = try XCTUnwrap(pouch.index)
            pouch.syncAttachment()
            for expanded in [false, true] {
                index.setExpanded(expanded); await h.layout()
                index.panel.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(250))
                let name = "\(dark ? "dark" : "light")-\(expanded ? "open" : "closed").png"
                // Capture only the synthetic backing window's rectangle. A
                // per-window image omits the desktop samples used by real glass.
                let rect = backdrop.frame
                let top = try XCTUnwrap(NSScreen.screens.first).frame.maxY
                let region = "\(Int(rect.minX)),\(Int(top - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-R", region, directory + "/" + name]
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            }
        }
    }
}
