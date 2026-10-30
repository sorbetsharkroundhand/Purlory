@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI
@testable import PurloryKoreanBackend

@MainActor
final class LivingMarginWorkspaceTests: XCTestCase {
    func testRailOpensAndClosesExistingPanelWithoutAnalysisOrEditorReplacement() async throws {
        let gate = WritingReportNativeGate(blockFirst: false)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let runtime = WritingDiagnosticsRuntime(worker: worker, observeEnergy: false)
        runtime.setSharedBackgroundPaused(true)
        let h = try await FramedWorkspaceHarness(width: 1440, presentationDefaults: [
            "purlory.sidebarSection": "bible", "purlory.toolDockPosition": "left"], writingDiagnostics: runtime)
        defer { runtime.stop(); h.close() }
        let editor = try await h.editor(), undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping(); editor.insertText("!", replacementRange: NSRange(location: 0, length: 0)); undo.endUndoGrouping()
        editor.setSelectedRange(NSRange(location: 2, length: 1)); await h.layout()
        let source = try XCTUnwrap(h.fixture.session.selectedDocument?.body), selection = editor.selectedRange()
        let button = try h.pouchItem("purlory.workspace.margin")
        XCTAssertEqual(button.title, "마진 노트")
        try h.performPouchAction("purlory.workspace.margin"); await h.layout()
        XCTAssertNotNil(h.element("purlory.living-margin"))
        let current = try await h.editor()
        XCTAssertTrue(current === editor); XCTAssertTrue(current.undoManager === undo); XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(current.selectedRange(), selection); XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertTrue(h.fixture.session.selectedDocument?.body.utf16.elementsEqual(source.utf16) == true)
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.toolDockPosition"), "left")
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.sidebarSection"), "bible")
        XCTAssertEqual(editor.enclosingScrollView?.bounds.width ?? -1, 948, accuracy: 1)
        h.fixture.session.selectWorkspaceMode(.outline); await h.layout()
        XCTAssertNotNil(h.element("purlory.living-margin")); XCTAssertNotNil(h.element("purlory.document-outline"))
        h.fixture.session.selectWorkspaceMode(.write); await h.layout()
        XCTAssertNotNil(h.element("purlory.living-margin"))
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.sidebarSection"), "bible")
        try h.performPouchAction("purlory.workspace.margin"); await h.layout()
        XCTAssertNil(h.element("purlory.living-margin"))
        XCTAssertEqual(editor.enclosingScrollView?.bounds.width ?? -1, 948, accuracy: 1)
        h.fixture.session.selectWorkspaceMode(.outline); await h.layout()
        try h.performPouchAction("purlory.workspace.margin"); await h.layout()
        XCTAssertEqual(h.fixture.session.workspaceMode, .outline)
        XCTAssertNotNil(h.element("purlory.living-margin")); XCTAssertNotNil(h.element("purlory.document-outline"))
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(gate.counts.opened, 0); XCTAssertEqual(gate.counts.analyzed, 0)
    }

    func testPreparedResultsNeverAutoOpenAndProjectSwitchRetiresExplicitOpening() async throws {
        let model = LivingMarginModel()
        let h = try await FramedWorkspaceHarness(presentationDefaults: ["purlory.sidebarSection": "margin"], livingMargin: model)
        defer { h.close() }
        XCTAssertNotNil(try h.pouchItem("purlory.workspace.margin")); XCTAssertNil(h.element("purlory.living-margin"))
        model.replace(writingQuality: [.init(id: "prepared", kind: .writingQuality, title: "맞춤법", message: "확인할 제안")])
        await h.layout()
        let button = try h.pouchItem("purlory.workspace.margin")
        XCTAssertNil(h.element("purlory.living-margin"), "A prepared result cannot change writing geometry")
        try h.performPouchAction("purlory.workspace.margin"); await h.layout()
        XCTAssertNotNil(h.element("purlory.living-margin"))
        let next = WritingProject(id: WritingProjectID(), title: "Other", mode: .fiction,
            documents: [.init(id: WritingDocumentID(), title: "Other", body: "Other", kind: .manuscript)])
        try await h.fixture.session.saveAndActivate(next); await h.layout()
        XCTAssertNil(h.element("purlory.living-margin"))
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.sidebarSection"), "margin")
    }
}
