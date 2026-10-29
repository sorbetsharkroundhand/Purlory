@testable import PurloryDocumentEngine
import AppKit
import XCTest
@testable import PurloryCore

@MainActor
final class StoryMapShellTests: XCTestCase {
    private func waitFor(_ identifier: String, in h: FramedWorkspaceHarness) async throws -> (any NSAccessibilityProtocol)? {
        for _ in 0..<100 {
            await h.layout()
            if let element = h.element(identifier) { return element }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
    func testActualFictionMapWorksWithAIOffAndKeepsEditorAcrossJumpReturnAndClose() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, mode: .fiction); defer { h.close() }
        let source = "# 첫 장면\n" + String(repeating: "집필을 이어가는 원문.\n", count: 60) + "# 둘째 장면\n나중 원문"
        h.fixture.session.updateSelectedDocumentBody(source); await h.layout()
        let editor = try await h.editor(), undo = try XCTUnwrap(editor.undoManager)
        editor.setSelectedRange(NSRange(location: 2, length: 1))
        editor.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 180))
        let selection = editor.selectedRange()
        h.window.makeFirstResponder(editor); h.fixture.session.selectWorkspaceMode(.map)
        let offset = DocumentOutline.parse(source).scenes[1].utf16Range.lowerBound
        let found = try await waitFor("purlory.story-map.row.scene:\(offset)", in: h)
        let row = try XCTUnwrap(found)
        XCTAssertNotNil(h.element("purlory.story-map"))
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
        let scroll = editor.enclosingScrollView?.contentView.bounds.origin
        try XCTUnwrap(row as? NSButton).performClick(nil); await h.layout()
        let expected = (editor.string as NSString).range(of: "둘째 장면", options: .backwards)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: expected.location, length: 0))
        let point = try XCTUnwrap(h.requests.sourceReturnPoint)
        XCTAssertEqual(point.selection, selection); XCTAssertEqual(point.scrollOrigin, scroll)
        XCTAssertGreaterThan(point.scrollOrigin.y, 0)
        let back = try XCTUnwrap(h.element("purlory.story-map.return"))
        try XCTUnwrap(back as? NSButton).performClick(nil); await h.layout()
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.enclosingScrollView?.contentView.bounds.origin, scroll)
        h.requests.spatialWorkspace?.selectTile(.map)
        h.requests.spatialWorkspace?.pouchSection = .object
        await h.layout()
        let closeControl = try await waitFor("purlory.tile.close.map", in: h)
        let close = try XCTUnwrap(closeControl)
        try XCTUnwrap(close as? NSButton).performClick(nil); await h.layout()
        XCTAssertEqual(h.fixture.session.workspaceMode, .write)
        XCTAssertNil(h.element("purlory.story-map"))
        let retained = try await h.editor(); XCTAssertTrue(retained === editor); XCTAssertTrue(editor.undoManager === undo)
        XCTAssertEqual(editor.selectedRange(), selection); XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(h.completion.engineState, .idle); XCTAssertFalse(h.completion.isManagingModel)
        XCTAssertFalse(h.completion.settings.autocompleteEnabled)
        XCTAssertTrue(editor.serialize().utf16.elementsEqual(source.utf16))
    }
    func testActualMapRetiresOnProjectSwitchAndGeneralKeepsItsOwnOutline() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, mode: .fiction); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("# 옛 지도\n원문"); h.fixture.session.selectWorkspaceMode(.map)
        let old = try await waitFor("purlory.story-map.row.scene:0", in: h)
        XCTAssertNotNil(old)
        let general = WritingProject(id: WritingProjectID(), title: "General", mode: .general,
            documents: [.init(id: WritingDocumentID(), title: "Note", body: "# 일반 개요\n본문", kind: .manuscript)])
        try await h.fixture.session.saveAndActivate(general); await h.layout()
        XCTAssertNil(h.element("purlory.story-map"))
        h.fixture.session.selectWorkspaceMode(.outline)
        let outline = try await waitFor("purlory.document-outline", in: h)
        XCTAssertNotNil(outline); XCTAssertNil(h.element("purlory.story-map"))
        XCTAssertEqual(h.fixture.session.activeProject?.id, general.id)
        XCTAssertEqual(h.completion.engineState, .idle)
    }
}
