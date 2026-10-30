@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class FramedWorkspaceTests: XCTestCase {
    func testPocketToolActionsPreserveCompositionAndToggleStoredTools() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction)
        defer { h.close() }
        let editor = try await h.editor(), manager = try XCTUnwrap(editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        defer { while manager.groupingLevel > 0 { manager.endUndoGrouping() } }
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        let selection = editor.selectedRange(), text = editor.string
        for (identifier, tile) in [("purlory.workspace.characters", WorkspaceTileID.characters),
                                       ("purlory.workspace.narrative", .narrative)] {
            try h.performPouchAction(identifier); await h.layout()
            XCTAssertTrue(h.requests.spatialWorkspace?.layout.contains(tile) == true)
            XCTAssertNotNil(h.fixture.defaults.data(forKey: "purlory.spatial-workspace.\(h.fixture.project.id.rawValue.uuidString)"))
            XCTAssertEqual(try h.pouchItem(identifier).state, .on)
            XCTAssertTrue(h.window.firstResponder === editor)
            XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange(), selection)
            try h.performPouchAction(identifier); await h.layout()
            XCTAssertFalse(h.requests.spatialWorkspace?.layout.contains(tile) == true)
            XCTAssertEqual(try h.pouchItem(identifier).state, .off)
        }
        editor.unmarkText(); editor.didChangeText()
    }

    func testLongProjectTitleKeepsNavigatorCloseInsideCard() async throws {
        let title = "Synthetic framed workspace matrix · 아주 긴 프로젝트 이름과 최근 작품 목록"
        for navigatorWidth in [200.0, 250.0, 360.0] {
            let h = try await FramedWorkspaceHarness(
                presentationDefaults: ["purlory.sidebarWidth": navigatorWidth], projectTitle: title)
            defer { h.close() }
            let editor = try await h.editor()
            for width: CGFloat in [860, 1180, 1440] {
                h.window.setContentSize(NSSize(width: width, height: 760)); await h.layout()
                let navigator = try XCTUnwrap(h.element("purlory.tile.navigator") as? NSView)
                let close = try XCTUnwrap(h.element("purlory.navigator.close") as? NSButton)
                let navigatorRect = navigator.convert(navigator.bounds, to: nil)
                let closeRect = close.convert(close.bounds, to: nil)
                XCTAssertGreaterThanOrEqual(closeRect.minX, navigatorRect.minX + 12)
                XCTAssertLessThanOrEqual(closeRect.maxX, navigatorRect.maxX,
                    "Long titles must not push the close button outside the clipped navigator")
                XCTAssertEqual(close.bounds.width, 28, accuracy: 0.5, "Navigator close controls retain their 28-point hit target")
                XCTAssertEqual(h.fixture.session.activeProject?.title, title)
            }
            try XCTUnwrap(h.element("purlory.navigator.close") as? NSButton).performClick(nil)
            await h.layout()
            XCTAssertTrue(h.window.firstResponder === editor)
        }
    }

    func testPouchExposesFunctionalActionsAndSelectedNavigatorState() async throws {
        let h = try await FramedWorkspaceHarness(presentationDefaults: ["purlory.sidebarVisible": true])
        defer { h.close() }
        h.window.orderFront(nil)
        let trigger = try XCTUnwrap(h.element("purlory.writer-tools.compatibility") as? NSButton)
        XCTAssertEqual(trigger.accessibilityLabel(), "주머니 열기")
        XCTAssertNotNil(trigger.target); XCTAssertNotNil(trigger.action)
        trigger.performClick(nil); await h.layout()
        XCTAssertNotNil(h.element("purlory.workspace.pouch.more"))
        let menu = try XCTUnwrap(h.requests.pouch).moreMenu()
        for identifier in ["purlory.workspace.navigator-toggle", "purlory.source-search.show", "purlory.workspace.settings"] {
            let item = try XCTUnwrap(menu.items.first { $0.accessibilityIdentifier() == identifier })
            XCTAssertNotNil(item.target); XCTAssertNotNil(item.action)
        }
        let files = try h.pouchItem("purlory.workspace.navigator-toggle")
        XCTAssertEqual(files.title, "파일 목록 숨기기")
        XCTAssertEqual(files.state, .on)
        try h.performPouchAction("purlory.workspace.navigator-toggle"); await h.layout()
        let hidden = try h.pouchItem("purlory.workspace.navigator-toggle")
        XCTAssertEqual(hidden.title, "파일 목록 보이기")
        XCTAssertEqual(hidden.state, .off)
        XCTAssertFalse(h.elements().contains { $0.accessibilityLabel() == "리빙 마진" })
    }

    func testRailToggleAndResizePreserveEditorAndPreferences() async throws {
        let h = try await FramedWorkspaceHarness(presentationDefaults: [
            "purlory.sidebarVisible": true, "purlory.sidebarWidth": 275.0, "purlory.toolDockPosition": "floating"])
        defer { h.close() }
        let editor = try await h.editor(), manager = try XCTUnwrap(editor.undoManager)
        manager.beginUndoGrouping(); editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        manager.endUndoGrouping(); editor.setSelectedRange(NSRange(location: 3, length: 4)); await h.layout()
        let key = h.requests.nativeEditorKey, project = h.fixture.session.activeProject, text = editor.string
        XCTAssertTrue(h.window.makeFirstResponder(editor))
        for width: CGFloat in [860, 1180, 1440] {
            h.window.setContentSize(NSSize(width: width, height: 760)); await h.layout()
            for _ in 0..<2 {
                try h.performPouchAction("purlory.workspace.navigator-toggle")
                await h.layout()
                let current = try await h.editor(); XCTAssertTrue(current === editor)
                XCTAssertTrue(h.window.firstResponder === editor)
                XCTAssertTrue(editor.undoManager === manager); XCTAssertTrue(manager.canUndo)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
                XCTAssertEqual(editor.string, text); XCTAssertEqual(h.requests.nativeEditorKey, key)
                XCTAssertEqual(h.fixture.session.activeProject, project)
            }
        }
        XCTAssertEqual(h.fixture.defaults.double(forKey: "purlory.sidebarWidth"), 275)
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.toolDockPosition"), "floating")
    }

    func testHiddenNavigatorSearchRequestIsConsumedOnce() async throws {
        let h = try await FramedWorkspaceHarness(presentationDefaults: ["purlory.sidebarVisible": false])
        defer { h.close() }
        let editor = try await h.editor()
        h.fixture.defaults.set(true, forKey: "purlory.sidebarVisible"); h.requests.focusSearch(); await h.layout()
        let search = try XCTUnwrap(h.field("프로젝트 검색"))
        let fieldEditor = try XCTUnwrap(search.currentEditor())
        XCTAssertTrue(h.window.firstResponder === fieldEditor)
        try XCTUnwrap(h.element("purlory.navigator.close") as? NSButton).performClick(nil); await h.layout()
        XCTAssertTrue(h.window.firstResponder === editor)
        h.fixture.defaults.set(true, forKey: "purlory.sidebarVisible"); await h.layout()
        XCTAssertNil(h.field("프로젝트 검색"), "Closing consumes the search request; reopening restores the compact source navigator")
        XCTAssertTrue(h.window.firstResponder === editor)
    }

    func testRailSearchHonorsMarkedTextAndEditability() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let editor = try await h.editor()
        let manager = try XCTUnwrap(editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        let selection = editor.selectedRange()
        let panels = NSApp.windows.filter { $0.title == "빠른 검색 및 명령" && $0.isVisible }.count
        try h.performPouchAction("purlory.source-search.show"); await h.layout()
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "빠른 검색 및 명령" && $0.isVisible }.count, panels)
        editor.unmarkText(); editor.didChangeText(); manager.endUndoGrouping()
        h.fixture.session.selectDocument(nil); await h.layout()
        XCTAssertFalse(try h.pouchItem("purlory.source-search.show").isEnabled)
    }

    func testDocumentToolbarRetainsLocalControlsWithoutDuplicateGlobalActions() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let host = NSHostingView(rootView: EditorToolbar(projectSession: h.fixture.session,
            editorRequests: h.requests, completion: h.completion, settings: h.completion.settings,
            theme: .light).defaultAppStorage(h.fixture.defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 52),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<25 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let controls = h.elements(in: host)
        for identifier in ["purlory.source-search.show", "purlory.writer-tools.compatibility",
                           "purlory.workspace.navigator-toggle", "purlory.workspace.settings"] {
            XCTAssertFalse(controls.contains { $0.accessibilityIdentifier() == identifier })
        }
        XCTAssertEqual(host.bounds.height, 36, accuracy: 0.5)
        // SwiftUI-only title/model/notice visibility is verified in the integrated app batch.

    }

    func testNavigatorAndToolReserveIndependentSpatialColumns() async throws {
        let h = try await FramedWorkspaceHarness(width: 1000, presentationDefaults: [
            "purlory.sidebarSection": "bible", "purlory.toolDockPosition": "left"])
        defer { h.close() }
        let editor = try await h.editor(), scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(scroll.bounds.width, 508, accuracy: 1)
        let close = try XCTUnwrap(h.element("purlory.navigator.close") as? NSButton)
        let manuscriptRect = scroll.convert(scroll.bounds, to: nil)
        let closeRect = close.convert(close.bounds, to: nil)
        XCTAssertLessThanOrEqual(closeRect.maxX, manuscriptRect.minX - 8)
        XCTAssertTrue(h.requests.spatialWorkspace?.layout.contains(.characters) == true)
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.toolDockPosition"), "left")
    }

    func testNavigatorColumnKeepsEditorAllocationAndIdentityAtNarrowWidths() async throws {
        let h = try await FramedWorkspaceHarness(presentationDefaults: [
            "purlory.sidebarVisible": true, "purlory.sidebarWidth": 250.0, "purlory.toolDockPosition": "left"], reduceMotion: true)
        defer { h.close() }
        let editor = try await h.editor()
        for width: CGFloat in [860, 1023, 1024, 1180, 1440] {
            let expected = width - 228
            h.window.setContentSize(NSSize(width: width, height: 760)); await h.layout()
            let current = try await h.editor(); XCTAssertTrue(current === editor)
            XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).bounds.width, expected, accuracy: 1)
            try XCTUnwrap(h.element("purlory.navigator.close") as? NSButton).performClick(nil)
            await h.layout()
            XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).bounds.width, width, accuracy: 1)
            h.fixture.defaults.set(true, forKey: "purlory.sidebarVisible"); await h.layout()
            XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).bounds.width, expected, accuracy: 1)
        }
        XCTAssertEqual(h.fixture.defaults.double(forKey: "purlory.sidebarWidth"), 250)
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.toolDockPosition"), "left")
        XCTAssertEqual(h.fixture.session.activeProject, h.initialProject)
    }

    func testResizePreservesEditorSelectionUndoAndMarkedText() async throws {
        for marked in [false, true] {
            let h = try await FramedWorkspaceHarness(); defer { h.close() }
            let editor = try await h.editor(), manager = try XCTUnwrap(editor.undoManager)
            let key = h.requests.nativeEditorKey
            manager.beginUndoGrouping()
            if marked {
                editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                    replacementRange: NSRange(location: 0, length: 0))
            } else {
                editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
                manager.endUndoGrouping(); editor.setSelectedRange(NSRange(location: 3, length: 4))
            }
            defer { while manager.groupingLevel > 0 { manager.endUndoGrouping() } }
            let text = editor.string, selection = editor.selectedRange()
            XCTAssertTrue(h.window.makeFirstResponder(editor))
            for width: CGFloat in [860, 1023, 1024, 1180, 1440] {
                h.window.setContentSize(NSSize(width: width, height: 760)); await h.layout()
                let current = try await h.editor(); XCTAssertTrue(current === editor)
                XCTAssertTrue(editor.undoManager === manager)
                XCTAssertTrue(h.window.firstResponder === editor)
                XCTAssertEqual(h.requests.nativeEditorKey, key)
                XCTAssertEqual(editor.selectedRange(), selection)
                XCTAssertEqual(editor.string, text)
                XCTAssertEqual(editor.hasMarkedText(), marked)
            }
            if marked { editor.unmarkText(); editor.didChangeText(); manager.endUndoGrouping() }
            else { XCTAssertTrue(manager.canUndo); manager.undo(); XCTAssertFalse(editor.string.hasPrefix("!")) }
        }
    }

    func testResizePreservesNavigatorSearchAndPendingRename() async throws {
        let h = try await FramedWorkspaceHarness(width: 1023); defer { h.close() }
        h.requests.focusSearch(); await h.layout()
        let search = try XCTUnwrap(h.field("프로젝트 검색"))
        let searchEditor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        searchEditor.insertText("original", replacementRange: NSRange(location: 0, length: 0))
        await h.layout()
        for width: CGFloat in [1024, 1023, 1180] {
            h.window.setContentSize(NSSize(width: width, height: 760)); await h.layout()
            XCTAssertTrue(h.field("프로젝트 검색") === search)
            XCTAssertEqual(searchEditor.string, "original")
        }
        searchEditor.insertText("", replacementRange: NSRange(location: 0, length: searchEditor.string.utf16.count))
        await h.layout(); h.requests.beginRename(); await h.layout()
        let rename = try XCTUnwrap(h.field("문서 이름"))
        let renameEditor = try XCTUnwrap(rename.currentEditor() as? NSTextView)
        renameEditor.insertText("Pending title", replacementRange: NSRange(location: 0, length: renameEditor.string.utf16.count))
        for width: CGFloat in [1023, 1024, 1180] {
            h.window.setContentSize(NSSize(width: width, height: 760)); await h.layout()
            XCTAssertTrue(h.field("문서 이름") === rename)
            XCTAssertEqual(renameEditor.string, "Pending title")
            XCTAssertEqual(h.fixture.session.selectedDocument?.title, "Manuscript")
        }
    }

    func testFrameSupportsDisplayAccessibilityOptions() async throws {
        let palette = PaletteSettings.shared
        let saved = (palette.enabled, palette.light, palette.dark)
        defer { palette.light = saved.1; palette.dark = saved.2; palette.enabled = saved.0 }
        for (scheme, motion, transparency, custom) in [(ColorScheme.light, false, false, false),
                (.dark, true, false, false), (.light, false, true, true), (.dark, true, true, true)] {
            palette.enabled = custom
            if custom { var light = palette.light; light.hexes[0] = 0xDDEEDD; palette.light = light }
            let h = try await FramedWorkspaceHarness(appearance: scheme,
                reduceMotion: motion, reduceTransparency: transparency); defer { h.close() }
            let editor = try await h.editor(), manager = try XCTUnwrap(editor.undoManager)
            manager.beginUndoGrouping(); editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
            manager.endUndoGrouping()
            let frame = try XCTUnwrap(h.element("purlory.workspace.frame") as? NSView)
            XCTAssertEqual(frame.layer?.backgroundColor, palette.theme(for: scheme).editorSurface.cgColor)
            XCTAssertEqual(frame.layer?.backgroundColor?.alpha, 1)
            try XCTUnwrap(h.element("purlory.navigator.close") as? NSButton).performClick(nil); await h.layout()
            let current = try await h.editor(); XCTAssertTrue(current === editor)
            XCTAssertTrue(h.window.firstResponder === editor)
            XCTAssertTrue(editor.undoManager === manager)
            XCTAssertTrue(manager.canUndo)
        }
    }

    func testFrameAndWindowTitleHaveSeparateSafeGeometry() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        var project = try XCTUnwrap(h.fixture.session.activeProject)
        project.title = String(repeating: "Long project title ", count: 30)
        try await h.fixture.session.saveAndActivate(project); await h.layout()
        let frame = try XCTUnwrap(h.element("purlory.workspace.frame") as? NSView)
        let chrome = try XCTUnwrap(h.element("purlory.workspace.chrome") as? NSView)
        let title = try XCTUnwrap(h.element("purlory.workspace.chrome.title") as? NSTextField)
        XCTAssertEqual(chrome.bounds.height, 36, accuracy: 0.5)
        XCTAssertEqual(frame.layer?.backgroundColor?.alpha, 1)
        XCTAssertEqual(frame.layer?.cornerRadius, 13)
        XCTAssertEqual(frame.layer?.masksToBounds, false, "Decoration must not clip editor transients")
        XCTAssertTrue(chrome.mouseDownCanMoveWindow)
        XCTAssertEqual(title.stringValue, project.title + "  /  " + (h.fixture.session.selectedDocument?.title ?? "") + "   1개 열림")
        let buttonsMaxX = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { h.window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil).maxX }.max() ?? 0
        let titleRect = title.convert(title.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(titleRect.minX, buttonsMaxX + 12)
        XCTAssertLessThanOrEqual(titleRect.maxX, chrome.convert(chrome.bounds, to: nil).maxX)
        XCTAssertEqual(title.maximumNumberOfLines, 1)
        XCTAssertEqual(title.lineBreakMode, .byTruncatingMiddle)
    }

    func testWindowTitleHitTestingReachesNativeDragRegion() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let chrome = try XCTUnwrap(h.element("purlory.workspace.chrome") as? NSView)
        let title = try XCTUnwrap(h.element("purlory.workspace.chrome.title") as? NSTextField)
        let point = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: h.host.superview)
        XCTAssertTrue(h.host.hitTest(point) === chrome, "The passive title routes hit testing to native window dragging")
        let empty = chrome.convert(NSPoint(x: 2, y: 2), to: h.host.superview)
        XCTAssertTrue(h.host.hitTest(empty) === chrome)
    }

    func testWindowTitleDragDelegatesOriginalPressToNativeWindowDragging() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let chrome = try XCTUnwrap(h.element("purlory.workspace.chrome") as? NSView)
        let title = try XCTUnwrap(h.element("purlory.workspace.chrome.title") as? NSTextField)
        let editor = try await h.editor()
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let originalStyle = h.window.styleMask
        let originalBackgroundDragging = h.window.isMovableByWindowBackground
        h.window.makeKeyAndOrderFront(nil)
        h.window.makeFirstResponder(editor)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 1, windowNumber: h.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(chrome.acceptsFirstMouse(for: event),
            "An inactive title region must accept the first press")
        title.mouseDown(with: event)
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged,
            location: NSPoint(x: event.locationInWindow.x + 10, y: event.locationInWindow.y),
            modifierFlags: [], timestamp: 1.1, windowNumber: h.window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        title.mouseDragged(with: moved)
        XCTAssertTrue(h.window.lastDragEvent === event,
            "A title press must hand the original event to native window dragging")
        XCTAssertEqual(h.window.styleMask, originalStyle)
        XCTAssertEqual(h.window.isMovableByWindowBackground, originalBackgroundDragging)
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
    }

    func testNavigatorLocalCloseReturnsToEditor() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let editor = try await h.editor()
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let before = h.fixture.session.activeProject
        let close = try XCTUnwrap(h.element("purlory.navigator.close") as? NSButton)
        XCTAssertEqual(close.bounds.width, 28)
        XCTAssertEqual(close.bounds.height, 28)
        XCTAssertEqual(close.accessibilityLabel(), "파일 목록 숨기기")
        close.performClick(nil); await h.layout()
        XCTAssertFalse(h.fixture.defaults.bool(forKey: "purlory.sidebarVisible"))
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
        XCTAssertEqual(h.fixture.session.activeProject, before)
    }

    func testSavedToolChoiceSurvivesWorkspaceAppearance() async throws {
        for section in ["bible", "timeline", "context"] {
            let h = try await FramedWorkspaceHarness(width: 1440, presentationDefaults: ["purlory.sidebarSection": section])
            defer { h.close() }
            let project = h.initialProject
            let selected = h.initialDocumentID
            await h.layout()
            XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.sidebarSection"), section)
            let editor = try await h.editor()
            XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).bounds.width, 948, accuracy: 1,
                "The saved tool must reserve its visible side pane")
            XCTAssertEqual(h.fixture.session.activeProject, project)
            XCTAssertEqual(h.fixture.session.selectedDocumentID, selected)
        }
    }

    func testUnknownAndDeferredToolChoicesRemainStoredAndQuiet() async throws {
        for section in ["margin", "unknown"] {
            let h = try await FramedWorkspaceHarness(presentationDefaults: ["purlory.sidebarSection": section])
            defer { h.close() }
            let project = h.initialProject
            let selected = h.initialDocumentID
            await h.layout()
            XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.sidebarSection"), section)
            let editor = try await h.editor()
            XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).bounds.width, 952, accuracy: 1,
                "Deferred and unknown tools must leave all writing space available")
            XCTAssertEqual(h.fixture.session.activeProject, project)
            XCTAssertEqual(h.fixture.session.selectedDocumentID, selected)
        }
    }
}

/// Hosts only a synthetic project; never launches the Purlory application.
@MainActor
final class FramedWorkspaceHarness {
    let fixture: LegacyBoundaryFixture
    let requests = ProjectEditorRequests()
    let initialProject: WritingProject?
    let initialDocumentID: WritingDocumentID?
    let window: FramedWorkspaceWindow
    let host: NSView
    let completion: CompletionController
    let indexer: BackgroundIndexer

    init(width: CGFloat = 1180, presentationDefaults: [String: Any] = [:],
         appearance: ColorScheme = .light, reduceMotion: Bool = false,
         reduceTransparency: Bool = false, projectTitle: String = "Project",
         writingDiagnostics: WritingDiagnosticsRuntime? = nil,
         livingMargin: LivingMarginModel? = nil, mode: WritingMode = .general,
         completionEngine: CompletionEngine = CompletionEngine()) async throws {
        fixture = try await LegacyBoundaryFixture(projectTitle: projectTitle, mode: mode)
        initialProject = fixture.session.activeProject
        initialDocumentID = fixture.session.selectedDocumentID
        for (key, value) in presentationDefaults { fixture.defaults.set(value, forKey: key) }
        let settings = CompletionSettings(defaults: fixture.defaults)
        settings.setCompletionEnabled(false)
        completion = CompletionController(settings: settings, engine: completionEngine)
        indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        window = FramedWorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testUndo.groupsByEvent = false
        window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        host = NSHostingView(rootView: ContentView(projectSession: fixture.session,
            startup: ProjectStartupCoordinator(session: fixture.session, store: fixture.store, storageLocation: .init(rootDirectory: fixture.legacyRoot)), editorRequests: requests, completion: completion,
            indexer: indexer, livingMargin: livingMargin ?? LivingMarginModel(), firstRunFlow: FirstRunFlow(
                session: fixture.session, store: fixture.store, editorRequests: requests),
            positionStore: WritingPositionStore(defaults: fixture.defaults), writingDiagnostics: writingDiagnostics)
            .defaultAppStorage(fixture.defaults)
            .environment(\.colorScheme, appearance)
            .environment(\.purloryWorkspaceAccessibilityOptions, WorkspaceAccessibilityOptions(
                systemReduceMotionOverride: reduceMotion, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)))
        window.contentView = host
        await layout()
    }

    func layout() async {
        // Geometry fixtures use overlay scrollers independently of host preferences.
        func prepare(_ view: NSView) {
            (view as? NSScrollView)?.scrollerStyle = .overlay
            view.subviews.forEach(prepare)
        }
        for _ in 0..<25 { prepare(host); host.layoutSubtreeIfNeeded(); await Task.yield() }
    }

    func editor() async throws -> BlockTextView {
        await layout()
        if let key = fixture.session.runtimeIdentity?.key, let editor = requests.editor(for: key) { return editor }
        func find(_ view: NSView) -> BlockTextView? {
            (view as? BlockTextView) ?? view.subviews.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(host))
    }

    func elements(in root: NSView? = nil) -> [any NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: AnyObject, depth: Int = 0) -> [any NSAccessibilityProtocol] {
            guard depth < 80, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var result: [any NSAccessibilityProtocol] = []
            if let element = object as? any NSAccessibilityProtocol {
                result.append(element)
                for child in element.accessibilityChildren() ?? [] {
                    result += walk(child as AnyObject, depth: depth + 1)
                }
            }
            if let view = object as? NSView {
                for child in view.subviews { result += walk(child, depth: depth + 1) }
            }
            return result
        }
        var result = walk(root ?? host)
        if root == nil, let pouch = requests.pouch?.panel?.contentView { result += walk(pouch) }
        return result
    }

    func element(_ identifier: String) -> (any NSAccessibilityProtocol)? {
        elements().first { $0.accessibilityIdentifier() == identifier }
    }

    func pouchItem(_ identifier: String) throws -> NSMenuItem {
        window.orderFront(nil)
        requests.pouch?.syncAttachment()
        let menu = try XCTUnwrap(requests.pouch).moreMenu()
        return try XCTUnwrap(menu.items.first { $0.accessibilityIdentifier() == identifier })
    }

    func performPouchAction(_ identifier: String) throws {
        let item = try pouchItem(identifier)
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    func field(_ placeholder: String) -> NSTextField? {
        elements().compactMap { $0 as? NSTextField }.first { $0.placeholderString == placeholder }
    }

    func close() {
        window.testUndo.removeAllActions(); window.contentView = nil; window.close()
        completion.shutdown(); indexer.shutdown(); fixture.cleanUp()
    }
}

@MainActor
final class FramedWorkspaceWindow: NSWindow {
    // Keep requested matrix sizes even on a hosted runner's 1024-point display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    let testUndo = UndoManager()
    var lastDragEvent: NSEvent?
    override var undoManager: UndoManager? { testUndo }
    override func performDrag(with event: NSEvent) { lastDragEvent = event }
}
