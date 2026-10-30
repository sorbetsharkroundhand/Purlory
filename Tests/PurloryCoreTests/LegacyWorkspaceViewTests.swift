@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class LegacyWorkspaceViewTests: XCTestCase {
    // Catches the representable replacing native state or leaving ordinary project editing fenced.
    func testProjectBridgeEditabilityUpdatesPreserveEditorSelectionAndUndo() async throws {
        let identity = EditorDocumentIdentity.project(ProjectDocumentKey(
            projectID: WritingProjectID(), documentID: WritingDocumentID()))
        let window = LegacyUndoWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testUndo.groupsByEvent = false
        let host = NSHostingView(rootView: PurloryBlockEditor(text: .constant("original"), documentIdentity: identity))
        window.contentView = host
        defer { window.testUndo.removeAllActions(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(findLegacyTestEditor(host))
        window.makeFirstResponder(editor)
        XCTAssertTrue(editor.isEditable, "Existing project callers must remain editable by default")
        let manager = try XCTUnwrap(editor.undoManager)
        manager.beginUndoGrouping()
        editor.insertText("!", replacementRange: NSRange(location: 8, length: 0))
        manager.endUndoGrouping()
        let selection = editor.selectedRange()
        for editable in [false, true] {
            host.rootView = PurloryBlockEditor(text: .constant("original!"), documentIdentity: identity,
                isEditable: editable)
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); await Task.yield() }
            XCTAssertTrue(findLegacyTestEditor(host) === editor)
            XCTAssertEqual(editor.isEditable, editable)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(manager.canUndo)
        }
        manager.undo()
        XCTAssertEqual(editor.serialize(), "original")
    }

    // Catches visible edits being accepted by NSTextView after its model write gate closes.
    func testFinalSaveFencesNativeLegacyEditorAndItsSwiftUIUpdates() async throws {
        let harness = try await LegacyViewHarness()
        defer { harness.close() }
        let editor = try await harness.editor()
        XCTAssertTrue(editor.isEditable)
        let selection = editor.selectedRange()
        try await harness.controller.flushForTermination()
        XCTAssertTrue(harness.controller.isTransitioning)
        XCTAssertFalse(editor.isEditable, "The native editor still accepts text after the last durable save")
        for _ in 0..<3 { await Task.yield(); harness.host.layoutSubtreeIfNeeded() }
        XCTAssertFalse(editor.isEditable, "A SwiftUI update reopened the fenced editor")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(harness.window.firstResponder === editor)
    }

    // Catches a failed leave dropping focus, pending IME text, editability or structural undo.
    func testFailedLeaveRestoresNativeEditorAfterCommittingMarkedText() async throws {
        try await assertFailedLeaveRestoresNativeEditor(failSave: false)
    }

    func testFailedLegacySaveRestoresNativeEditorAfterCommittingMarkedText() async throws {
        try await assertFailedLeaveRestoresNativeEditor(failSave: true)
    }

    private func assertFailedLeaveRestoresNativeEditor(failSave: Bool) async throws {
        let harness = try await LegacyViewHarness()
        defer { harness.close() }
        let editor = try await harness.editor()
        if failSave {
            try FileManager.default.setAttributes([.posixPermissions: 0o555],
                ofItemAtPath: harness.fixture.legacyRoot.path)
        } else {
            let marker = harness.fixture.root.appendingPathComponent("Projects/active-project.json")
            try Data("corrupt marker".utf8).write(to: marker)
        }
        // The deterministic window manager has no event-driven grouping. Native IME edits
        // must run inside a group, as they do inside an AppKit input event.
        harness.window.testUndo.beginUndoGrouping()
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        do { try await harness.controller.leave(); XCTFail("Failed persistence released the owner") } catch {}
        harness.window.testUndo.endUndoGrouping()
        XCTAssertFalse(editor.hasMarkedText(), "The transition did not commit the IME composition")
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(harness.window.firstResponder === editor)
        XCTAssertTrue(harness.owner.structureUndoManager === editor.undoManager)
        XCTAssertEqual(harness.owner.activeEntry?.body, editor.serialize())
        XCTAssertTrue(editor.serialize().contains("한"))
    }

    // Catches an unwired compatibility view: Cmd-Z must restore real store structure.
    func testCompatibilityEditorUsesWindowUndoAndDetachesItOnLeave() async throws {
        let harness = try await LegacyViewHarness()
        defer { harness.close() }
        let editor = try await harness.editor()
        XCTAssertTrue(editor.undoManager === harness.window.undoManager)
        let owner = harness.owner
        let id = owner.activeID
        let folder = owner.newFolder()
        let manager = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(owner.structureUndoManager === manager, "The active store is not connected to the editor undo manager")
        manager.removeAllActions()
        manager.beginUndoGrouping()
        owner.move(id, toFolder: folder)
        manager.endUndoGrouping()
        XCTAssertEqual(owner.activeEntry?.folderID, folder)
        XCTAssertTrue(manager.canUndo)
        if manager.canUndo { manager.undo() }
        XCTAssertNil(owner.activeEntry?.folderID, "Undo action: \(manager.undoActionName), redo: \(manager.redoActionName)")
        if manager.canRedo { manager.redo() }
        try await harness.controller.leave()
        XCTAssertNil(owner.structureUndoManager)
        XCTAssertFalse(manager.canUndo)
        let entries = owner.entries
        if manager.canUndo { manager.undo() }
        XCTAssertEqual(owner.entries, entries, "A departed store remained reachable through undo")
    }
}

@MainActor
final class LegacyViewHarness {
    let fixture: LegacyBoundaryFixture
    let controller: LegacyWorkspaceController
    let owner: EntryStore
    let completion: CompletionController
    let indexer: BackgroundIndexer
    let window: LegacyUndoWindow
    let host: NSHostingView<LegacyWorkspaceView>

    init() async throws {
        fixture = try await LegacyBoundaryFixture()
        controller = fixture.controller()
        try await controller.enter()
        owner = try XCTUnwrap(controller.legacyStore)
        let settings = CompletionSettings(defaults: fixture.defaults)
        completion = CompletionController(settings: settings)
        indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        window = LegacyUndoWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testUndo.groupsByEvent = false
        host = NSHostingView(rootView: LegacyWorkspaceView(
            workspace: controller, store: owner, completion: completion, settings: settings, indexer: indexer,
            updateBody: { [weak controller] in controller?.updateLegacyBody($0) }))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
    }

    func editor() async throws -> BlockTextView {
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if let editor = findLegacyTestEditor(host) {
                window.makeFirstResponder(editor)
                return editor
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTUnwrapFailure.missingEditor
    }

    func close() {
        window.testUndo.removeAllActions()
        window.contentView = nil
        window.close()
        completion.shutdown()
        indexer.shutdown()
        fixture.cleanUp()
    }
}

@MainActor
final class LegacyUndoWindow: NSWindow {
    let testUndo = UndoManager()
    override var undoManager: UndoManager? { testUndo }
}

private enum XCTUnwrapFailure: Error { case missingEditor }

@MainActor
private func findLegacyTestEditor(_ view: NSView) -> BlockTextView? {
    if let editor = view as? BlockTextView { return editor }
    return view.subviews.lazy.compactMap { findLegacyTestEditor($0) }.first
}
