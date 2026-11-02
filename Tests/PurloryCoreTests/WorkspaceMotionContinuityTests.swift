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

    func testParagraphTargetingDoesNotChangeRichTextOrLayout() async throws {
        let h = try await FramedWorkspaceHarness(width: 1440, reduceMotion: false)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let a = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        h.fixture.session.updateSelectedDocumentBody("First\n**이동🙂** $x$\nLast\n")
        let b = try XCTUnwrap(h.fixture.session.createDocument(title: "Target"))
        h.fixture.session.updateSelectedDocumentBody("> Target\nAnother paragraph\n")
        let model = try XCTUnwrap(h.requests.spatialWorkspace)
        var split = model.layout; split.move(.document(b), to: .after(.document(a)))
        model.setLayout(split); await h.layout()
        let project = try XCTUnwrap(h.fixture.session.activeProject?.id)
        let source = try XCTUnwrap(h.requests.editor(for: .init(projectID: project, documentID: a)))
        let target = try XCTUnwrap(h.requests.editor(for: .init(projectID: project, documentID: b)))
        let interaction = try XCTUnwrap(source.workspaceInteraction as? WorkspaceEditorInteraction)
        let targetInteraction = try XCTUnwrap(target.workspaceInteraction as? WorkspaceEditorInteraction)
        let original = NSAttributedString(attributedString: try XCTUnwrap(target.textStorage))
        let rect = try XCTUnwrap(targetInteraction.paragraphRect(at: 0))
        let offset = (source.string as NSString).range(of: "이동🙂").location
        let grip = try XCTUnwrap(interaction.paragraphGrip(at: offset))
        XCTAssertTrue(interaction.mouseDown(try event(.leftMouseDown, in: source,
            at: CGPoint(x: grip.midX, y: grip.midY), modifiers: [.option])))
        for y in [rect.minY + 1, rect.maxY - 1] {
            XCTAssertTrue(interaction.mouseDragged(try event(.leftMouseDragged, in: target,
                at: CGPoint(x: rect.midX, y: y), modifiers: [.option])))
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertTrue(try XCTUnwrap(target.textStorage).isEqual(to: original),
                "Insertion feedback must not rewrite manuscript paragraph attributes")
            XCTAssertEqual(targetInteraction.paragraphRect(at: 0), rect)
        }
        interaction.detach()
        XCTAssertTrue(try XCTUnwrap(target.textStorage).isEqual(to: original))
        XCTAssertEqual(h.fixture.session.document(b)?.body, "> Target\nAnother paragraph\n")
    }

    private func event(_ type: NSEvent.EventType, in view: NSView, at point: CGPoint,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 1, windowNumber: try XCTUnwrap(view.window).windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
