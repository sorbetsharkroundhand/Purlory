@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class HTMLWorkspaceFidelityTests: XCTestCase {
    func testSpatialSelectionRestoresFormattingToolbarAndPreservesEditorFocus() async throws {
        let h = try await FramedWorkspaceHarness(width: 860, reduceMotion: true)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        h.fixture.session.updateSelectedDocumentBody("서식을 적용할 문장.")
        let editor = try await h.editor(); h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 3)); editor.updateSelectionToolbar()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(editor.workspaceSelectionPanel)
        XCTAssertEqual(editor.workspaceSelectionPanel?.canBecomeKey, true)
        XCTAssertEqual(editor.workspaceSelectionPanel?.becomesKeyOnlyIfNeeded, true)
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 3), "Presenting selection toolbar must not trigger selectAll on BlockTextView")
        let toolbar = try XCTUnwrap(editor.workspaceSelectionPanel?.contentView)
        let controls = h.elements(in: toolbar)
        for identifier in ["font-size.smaller", "font-size.value", "font-size.larger", "color.default", "color.FF453A", "polish"] {
            XCTAssertTrue(controls.contains { $0.accessibilityIdentifier() == "purlory.selection.\(identifier)" })
        }
        XCTAssertTrue(controls.contains { $0.accessibilityLabel() == "빨강" })
        XCTAssertFalse(controls.contains { $0.accessibilityLabel() == "메모 발췌" })
        XCTAssertFalse(controls.contains { $0.accessibilityLabel() == "FF453A" })
        editor.perform(.fontSize(18.5))
        XCTAssertEqual(editor.currentSelectionState().fontSize, 18.5)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 3))
        editor.perform(.fontSize(22))
        await h.layout()
        XCTAssertEqual(editor.currentSelectionState().fontSize, 22)
        let updatedControls = h.elements(in: try XCTUnwrap(editor.workspaceSelectionPanel?.contentView))
        XCTAssertTrue(updatedControls.contains { $0.accessibilityIdentifier() == "purlory.selection.font-size.value" && ($0.accessibilityValue() as? String) == "22" })
        editor.perform(.color("FF453A"))
        XCTAssertEqual(editor.currentSelectionState().colorHex, "FF453A")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertNotNil(editor.workspaceSelectionPanel)
    }
    func testSecondaryMenuKeepsModesAndAIStateAccessible() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction); defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let pouch = try XCTUnwrap(h.requests.pouch)
        let menu = pouch.moreMenu()
        XCTAssertTrue(menu.items.contains { $0.accessibilityIdentifier() == "purlory.workspace.mode.map" })
        let write = try XCTUnwrap(menu.items.first { $0.accessibilityIdentifier() == "purlory.workspace.mode.write" })
        XCTAssertEqual(write.state, .on)
        let ai = try XCTUnwrap(menu.items.first { $0.accessibilityIdentifier() == "purlory.workspace.autocomplete" })
        XCTAssertEqual(ai.title, "자동완성 꺼짐")
        XCTAssertEqual(ai.state, .off)
        let details = try XCTUnwrap(menu.items.firstIndex { $0.accessibilityIdentifier() == "purlory.workspace.more.characters" })
        menu.performActionForItem(at: details); await h.layout()
        XCTAssertEqual(h.requests.spatialWorkspace?.selectedTile, .characters)
        XCTAssertNil(h.requests.spatialWorkspace?.pouchSection)
        XCTAssertNotNil(h.window.attachedSheet)
    }
    func testFixedPouchKeepsControlsSeparateFromDocumentFormatting() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID).rawValue.uuidString
        XCTAssertNil(h.element("purlory.tile.typewriter.\(id)"))
        XCTAssertNil(h.element("purlory.tile.focus.\(id)"))
        XCTAssertNil(h.element("purlory.tile.continue.\(id)"))
        let spatial = try XCTUnwrap(h.requests.spatialWorkspace)
        let before = spatial.layout
        let canvas = try XCTUnwrap(spatial.canvas)
        let frames = canvas.geometry.tiles
        let extent = canvas.geometry.contentSize
        spatial.openPouchTools(); await h.layout()
        let trigger = try XCTUnwrap(spatial.pouchAnchor)
        let triggerButton = try XCTUnwrap(trigger as? NSButton)
        XCTAssertEqual(triggerButton.title, "")
        XCTAssertEqual(triggerButton.imagePosition, .imageOnly)
        XCTAssertFalse(trigger.superview is SpatialTileHeaderView)
        XCTAssertFalse(trigger.isHidden)
        let triggerFrame = trigger.convert(trigger.bounds, to: nil)
        spatial.selectTile(.navigator); await h.layout()
        XCTAssertEqual(trigger.convert(trigger.bounds, to: nil), triggerFrame)
        XCTAssertEqual(spatial.layout, before)
        XCTAssertEqual(canvas.geometry.tiles, frames, "The pouch must overlay existing objects without moving or resizing them")
        XCTAssertEqual(canvas.geometry.contentSize, extent, "An overlay must not reserve scroll space")
        XCTAssertEqual(spatial.pouchSection, .overview)
        XCTAssertFalse(spatial.layout.contains(.inspector))
        XCTAssertNil(h.element("purlory.workspace.pouch.index.format"))
        XCTAssertNil(h.element("purlory.workspace.pouch.index.ai"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.dismiss"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.more"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.autocomplete"))
        XCTAssertNil(h.element("purlory.workspace.pouch.character-format"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.appearance"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.appearance.light"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.appearance.dark"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.font-size"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.line-spacing"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.typewriter"))
        XCTAssertNotNil(h.element("purlory.workspace.pouch.focus"))
        let pouch = try XCTUnwrap(h.requests.pouch)
        pouch.dismissTools()
        XCTAssertNil(spatial.pouchSection, "Dismissal must be synchronous, without an animation delay")
        XCTAssertEqual(canvas.geometry.tiles, frames)
    }

    func testPaletteShowsCategoryTitleAndDetailWithoutNativeWindowChrome() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        let editor = try await h.editor(); h.window.makeFirstResponder(editor)
        let panel = try XCTUnwrap(WorkspaceQuickCommandPanel.present(session: h.fixture.session, requests: h.requests, theme: .light, toggleTheme: {}))
        defer { panel.close() }
        await h.layout()
        let window = try XCTUnwrap(panel.window)
        XCTAssertFalse(window.styleMask.contains(.titled))
        let labels = descendants(try XCTUnwrap(window.contentView)).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("현재 문단을 화면 눈높이 중앙에 유지"), "Result descriptions must be visible, not only searchable")
        XCTAssertTrue(labels.contains("명령"))
        XCTAssertTrue(labels.contains("ESC"))
    }

    func testWorkspaceSubtitleUsesSourceScaleAndMutedInk() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("# 제목\n\n## 부제\n\n원고 본문")
        await h.layout()
        let editor = try await h.editor()
        let attrs = editor.styleAttributes(for: .h2, checked: false)
        XCTAssertEqual(try XCTUnwrap(attrs[.font] as? NSFont).pointSize, editor.baseFontSize * 1.12, accuracy: 0.01)
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, editor.palette.workspaceMuted)
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

    func testCharacterCardsRemainVisibleWhenAnotherDocumentIsActive() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true, mode: .fiction)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let card = CharacterCard(name: "도경", aliases: "등대지기", note: "면장갑을 낀다.")
        try ProjectWriterEditing.perform(.character(card), in: h.fixture.session, identity: XCTUnwrap(h.fixture.session.runtimeIdentity))
        _ = h.fixture.session.createDocument(title: "다른 문서")
        await h.layout()
        h.requests.spatialWorkspace?.toggle(.characters); await h.layout()
        try await Task.sleep(for: .milliseconds(400)); h.host.displayIfNeeded(); await h.layout()
        XCTAssertNotNil(h.element("purlory.card.\(card.id.uuidString)"), "Visible elements: \(h.elements().map { ($0.accessibilityIdentifier() ?? "") + ":" + ($0.accessibilityLabel() ?? "") }.joined(separator: " | "))")
    }

    func testOldCharacterDataDecodesWithoutNewEditorialFields() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"도경","aliases":"","note":"원래 기록"}"#
        let card = try JSONDecoder().decode(CharacterCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.note, "원래 기록"); XCTAssertNil(card.role); XCTAssertNil(card.traits)
    }

    func testOpeningAToolProportionsNeighborFramesOverTime() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: false)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        let canvas = try XCTUnwrap(descendants(h.host).compactMap { $0 as? SpatialWorkspaceCanvasView }.first)
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let host = try XCTUnwrap(canvas.hosts[.document(id)])
        let original = host.frame
        var animationTime = 0.0
        canvas.frameAnimationTime = { animationTime }
        let originalEditor = try await h.editor()
        model.toggle(.characters); await h.layout()
        let destination = try XCTUnwrap(canvas.geometry.tiles[.document(id)])
        XCTAssertLessThan(destination.width, original.width)
        XCTAssertGreaterThan(host.frame.width, destination.width + 1, "Opening must animate the neighboring document instead of teleporting")
        animationTime = 0.05
        canvas.stepFrames()
        XCTAssertGreaterThan(host.frame.width, destination.width)
        XCTAssertLessThan(host.frame.width, original.width)
        animationTime = 1
        canvas.stepFrames(); await h.layout()
        XCTAssertEqual(host.frame.width, destination.width, accuracy: 1)
        let retained = try await h.editor()
        XCTAssertTrue(retained === originalEditor)
    }
}
