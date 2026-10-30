@testable import PurloryIntelligence
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class WriterCompatibilityTests: XCTestCase {
    func testRailExposesAccessibleSearchAndCompatibilityMenuInGeneral() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let controls = h.elements()
        let search = try h.pouchItem("purlory.source-search.show")
        let compatibility = try XCTUnwrap(controls.first { $0.accessibilityIdentifier() == "purlory.writer-tools.compatibility" })
        XCTAssertEqual(search.title, "검색 · 문서, 원문, 도구 찾기")
        XCTAssertEqual(compatibility.accessibilityLabel(), "주머니 열기")
        XCTAssertFalse(controls.contains { $0.accessibilityLabel() == "리빙 마진" })
        let menu = try XCTUnwrap(h.requests.pouch).moreMenu()
        for title in ["인물과 작품 정보", "작가 수정과 기록", "제안에 쓰인 내용", "원문 검색", "설정"] {
            XCTAssertTrue(menu.items.contains { $0.title == title })
        }
        XCTAssertNotNil(menu.items.first?.image)
        XCTAssertNotNil(search.target); XCTAssertNotNil(search.action)
        XCTAssertNotNil((compatibility as? NSButton)?.action)
        let view = try await h.editor(), before = h.fixture.session.activeProject
        view.setSelectedRange(NSRange(location: 3, length: 4))
        let selection = view.selectedRange()
        for (identifier, target) in [("purlory.workspace.more.characters", WorkspaceTileID.characters), ("purlory.workspace.more.narrative", .narrative), ("purlory.workspace.context", .context)] {
            let item = try XCTUnwrap(menu.items.first { $0.accessibilityIdentifier() == identifier })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            await h.layout()
            XCTAssertTrue(h.requests.spatialWorkspace?.layout.contains(target) == true)
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertEqual(h.fixture.session.activeProject, before)
        }
        h.window.setContentSize(NSSize(width: 860, height: 760)); await h.layout()
        if let sheet = h.window.attachedSheet { h.window.endSheet(sheet) }
        try h.performPouchAction("purlory.source-search.show")
        await h.layout()
        XCTAssertNotNil(h.element("purlory.workspace.search.query"))
        try XCTUnwrap(h.element("purlory.tile.close.search") as? NSButton).performClick(nil)
        await h.layout()
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(h.fixture.session.activeProject, before)
        XCTAssertTrue(h.window.firstResponder === view)
    }

    func testGeneralStillShowsExistingGenreAndCharacterFieldsWithoutChangingUserData() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let identity = try XCTUnwrap(h.fixture.session.runtimeIdentity)
        let writer = WriterDocumentData(documentID: identity.key.documentID, genre: "Saved genre",
            characters: [CharacterCard(name: "미나", aliases: "민아", note: "Saved decisions")])
        let bytes = try writer.encoded()
        try h.fixture.session.updateUserData(bytes, for: WriterDocumentData.key(for: writer.documentID), identity: identity)
        let before = h.fixture.session.activeProject
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ProjectWriterToolsView(session: h.fixture.session,
            completion: h.completion, editorRequests: h.requests, section: .bible, theme: .light))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        func fields(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(fields)
        }
        let visible = fields(host)
        XCTAssertTrue(visible.contains("Saved genre"), "Existing genre must remain editable in the compatibility route")
        XCTAssertTrue(visible.contains("미나"), "Existing character must remain reachable after switching to General")
        XCTAssertEqual(h.fixture.session.activeProject, before)
        XCTAssertEqual(h.fixture.session.selectedDocumentSnapshot?.userData[WriterDocumentData.key(for: writer.documentID)], bytes)
    }
}
