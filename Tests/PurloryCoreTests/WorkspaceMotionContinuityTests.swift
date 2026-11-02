import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class WorkspaceMotionContinuityTests: XCTestCase {
    func testGrabbingReflowKeepsVisibleFramesAndClickReleaseResumesLayout() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: false)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let model = try XCTUnwrap(h.requests.spatialWorkspace), canvas = try XCTUnwrap(model.canvas)
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let editor = try await h.editor()
        var time = 0.0
        canvas.frameAnimationTime = { time }
        model.toggle(.characters); await h.layout()
        let host = try XCTUnwrap(canvas.hosts[.document(id)])
        let destination = try XCTUnwrap(canvas.geometry.tiles[.document(id)])
        time = 0.04; canvas.stepFrames()
        let visible = host.frame
        XCTAssertNotEqual(visible, destination)
        let point = CGPoint(x: visible.minX + 40, y: visible.minY + 16)
        canvas.beginPanelDrag(.document(id), event: try event(.leftMouseDown, in: canvas, at: point))
        await h.layout()
        XCTAssertEqual(host.frame, visible, "Pointer-down must freeze the visible frame, not finish the reflow")
        XCTAssertEqual(model.baseDragGeometry?.tiles[.document(id)], visible)
        canvas.finishPanelDrag(try event(.leftMouseUp, in: canvas, at: point))
        time = 1; canvas.stepFrames(); await h.layout()
        XCTAssertEqual(host.frame, destination)
        let retained = try await h.editor()
        XCTAssertTrue(retained === editor)
    }

    func testOldSnapshotCompletionCannotBrightenANewerDrag() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: false)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let model = try XCTUnwrap(h.requests.spatialWorkspace), canvas = try XCTUnwrap(model.canvas)
        let id = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let host = try XCTUnwrap(canvas.hosts[.document(id)])
        func beginDrag() throws -> CGPoint {
            let frame = host.frame
            let start = CGPoint(x: frame.midX, y: frame.minY + 16)
            let end = CGPoint(x: frame.midX, y: frame.midY)
            canvas.beginPanelDrag(.document(id), event: try event(.leftMouseDown, in: canvas, at: start))
            canvas.continuePanelDrag(try event(.leftMouseDragged, in: canvas, at: end))
            XCTAssertTrue(model.isDragging)
            XCTAssertFalse(model.isTabDrop)
            return end
        }
        let firstEnd = try beginDrag()
        canvas.finishPanelDrag(try event(.leftMouseUp, in: canvas, at: firstEnd))
        await h.layout()
        _ = try beginDrag()
        XCTAssertEqual(host.alphaValue, 0.35, accuracy: 0.01)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.isDragging)
        XCTAssertEqual(host.alphaValue, 0.35, accuracy: 0.01,
            "Canceled snapshot completion must not overwrite the next gesture's appearance")
        canvas.cancelInteraction()
        XCTAssertEqual(host.alphaValue, 1)
    }

    private func event(_ type: NSEvent.EventType, in view: NSView, at point: CGPoint,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 1, windowNumber: try XCTUnwrap(view.window).windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
