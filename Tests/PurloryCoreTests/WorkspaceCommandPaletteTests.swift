@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class WorkspaceCommandPaletteTests: XCTestCase {
    func testOriginalSearchExcludesCodeAndMathBlockContents() {
        let document = WritingDocument(id: WritingDocumentID(), title: "Draft",
            body: "```swift\nneedle in code\n```\n$$\nneedle in math\n$$\nVisible needle.", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Search", mode: .general, documents: [document])
        let results = WorkspaceCommandSearch.items(in: project, query: "needle", typewriter: false, focus: false)
        XCTAssertEqual(results.filter { $0.kind == .source }.map(\.title), ["Visible needle."])
    }
    func testTitleDoesNotSearchAndPouchOpensEmbeddedSearch() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let editor = try await h.editor(); h.window.makeFirstResponder(editor)
        let title = try XCTUnwrap(h.element("purlory.workspace.chrome.title") as? NSTextField)
        XCTAssertFalse(title.accessibilityPerformPress())
        XCTAssertTrue(h.window.firstResponder === editor)
        let pouch = try XCTUnwrap(h.requests.pouch)
        let search = try XCTUnwrap(pouch.actions.first { $0.id == "purlory.source-search.show" })
        search.perform()
        await h.layout()
        XCTAssertTrue(h.requests.spatialWorkspace?.layout.contains(.search) == true)
        XCTAssertNotNil(h.element("purlory.workspace.search.query"))
        XCTAssertTrue(h.requests.nativeEditor === editor)
    }
    func testCommandsFilesCharactersAndOriginalsUseTheNineResultLimit() throws {
        let a = WritingDocument(id: WritingDocumentID(), title: "Chapter", body: "한도경은 바람을 들었다.\n", kind: .manuscript)
        var project = WritingProject(id: WritingProjectID(), title: "Commands", mode: .fiction, documents: [a])
        let writer = WriterDocumentData(documentID: a.id, characters: [CharacterCard(name: "한도경", note: "등대지기")])
        project.userData[WriterDocumentData.key(for: a.id)] = try writer.encoded()
        let empty = WorkspaceCommandSearch.items(in: project, query: "", typewriter: false, focus: false)
        XCTAssertTrue(empty.contains { $0.kind == .command && $0.title.contains("타자기") })
        XCTAssertTrue(empty.contains { $0.kind == .file })
        XCTAssertTrue(empty.contains { $0.kind == .character })
        XCTAssertTrue(empty.contains { $0.kind == .source })
        XCTAssertTrue(WorkspaceCommandSearch.items(in: project, query: "원문", typewriter: false, focus: false).contains { $0.kind == .source })
        let matches = WorkspaceCommandSearch.items(in: project, query: "한도경", typewriter: false, focus: false)
        XCTAssertTrue(matches.contains { $0.kind == .character })
        let source = try XCTUnwrap(matches.first { $0.kind == .source })
        guard case .source(let reference) = source.action else { return XCTFail("Missing exact source reference") }
        XCTAssertTrue(reference.matchesSource(a.body))
        for index in 0..<20 { project.documents.append(WritingDocument(id: WritingDocumentID(), title: "File \(index)", body: "Body", kind: .note)) }
        XCTAssertEqual(WorkspaceCommandSearch.items(in: project, query: "", typewriter: true, focus: true).count, 9)
        XCTAssertTrue(WorkspaceCommandSearch.items(in: project, query: "does not exist", typewriter: false, focus: false).isEmpty)
    }

    func testNativePaletteOpensAClosedSourceTileAtTheExactOriginal() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: true)
        defer { h.close() }
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Closed target"))
        h.fixture.session.updateSelectedDocumentBody("Before\n\nExact original needle🙂\nAfter")
        await h.layout()
        _ = h.fixture.session.createDocument(title: "Third retained tile")
        await h.layout()
        h.fixture.session.selectDocument(a); await h.layout()
        let originalEditor = try XCTUnwrap(h.requests.nativeEditor)
        h.window.makeFirstResponder(originalEditor)
        _ = h.requests.spatialWorkspace?.close(.document(b)); await h.layout()
        let panel = try XCTUnwrap(WorkspaceQuickCommandPanel.present(session: h.fixture.session, requests: h.requests,
            theme: .light, toggleTheme: {}))
        defer { panel.close() }
        panel.searchField.stringValue = "needle"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchField))
        XCTAssertTrue(panel.control(panel.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await h.layout()
        XCTAssertEqual(h.fixture.session.selectedDocumentID, b)
        XCTAssertEqual(h.requests.nativeEditorKey?.documentID, b)
        let editor = try XCTUnwrap(h.requests.nativeEditor)
        XCTAssertFalse(editor === originalEditor)
        XCTAssertTrue(h.requests.spatialWorkspace?.layout.openDocuments.contains(a) == true)
        let selected = editor.selectedRange()
        XCTAssertGreaterThan(selected.location, 0)
        XCTAssertTrue((editor.string as NSString).substring(with: selected).contains("needle"))
    }
}
