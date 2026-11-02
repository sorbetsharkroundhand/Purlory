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

    private func event(_ type: NSEvent.EventType, in view: NSView, at point: CGPoint,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 1, windowNumber: try XCTUnwrap(view.window).windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
