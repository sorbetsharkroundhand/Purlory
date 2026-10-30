@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class WorkspacePouchTests: XCTestCase {
    func testMeasuredPouchHeightIsIndependentOfTileSelection() {
        let model = SpatialWorkspaceController(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        model.selectTile(.navigator); model.pouchSection = .overview
        model.setPouchContentHeight(184, for: .navigator)
        XCTAssertEqual(model.pouchContentHeight, 184)
        model.setPouchContentHeight(630, for: .navigator)
        XCTAssertEqual(model.pouchContentHeight, 630)
        model.setPouchContentHeight(184, for: .navigator)
        model.setPouchContentHeight(.nan, for: .navigator)
        XCTAssertEqual(model.pouchContentHeight, 184)
        model.selectTile(.characters)
        model.setPouchContentHeight(630, for: .navigator)
        XCTAssertEqual(model.pouchContentHeight, 630)
    }

    func testAttachingPouchPreservesNativeTrafficLightActions() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let miniaturize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let closeAction = close.action, minimizeAction = miniaturize.action
        let closeTarget = close.target as AnyObject?, minimizeTarget = miniaturize.target as AnyObject?
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let pouch = WorkspacePouchController(model: SpatialWorkspaceController(defaults: defaults), defaults: defaults)
        pouch.attach(to: window)
        defer { pouch.detach(); window.close() }
        XCTAssertEqual(close.action, closeAction); XCTAssertTrue(close.target as AnyObject? === closeTarget)
        XCTAssertEqual(miniaturize.action, minimizeAction); XCTAssertTrue(miniaturize.target as AnyObject? === minimizeTarget)
        XCTAssertFalse(pouch.isCollapsed)
    }

    func testPopoverKeepsItsWidthOnNarrowObjectsAndFitsTheViewport() throws {
        let visible = CGRect(x: 0, y: 0, width: 900, height: 700)
        let object = CGRect(x: 8, y: 8, width: 165, height: 640)
        let placement = try XCTUnwrap(WorkspacePouchPlacement(anchor: CGRect(x: object.maxX - 66, y: object.minY + 2, width: 28, height: 28), visible: visible, toolHeight: 520))
        let card = placement.card.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY)
        XCTAssertEqual(card.width, 304)
        XCTAssertTrue(visible.contains(card))
        XCTAssertGreaterThan(card.maxX, object.maxX, "Narrow objects must not clip or compress the overlay")
        XCTAssertFalse(card.intersects(placement.trigger.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY)))
    }

    func testFixedChromeAnchorOpensInsideTheCanvasWithoutReservingSpace() throws {
        let visible = CGRect(x: 0, y: 0, width: 860, height: 504)
        let anchor = CGRect(x: 818, y: -32, width: 28, height: 28)
        let placement = try XCTUnwrap(WorkspacePouchPlacement(anchor: anchor, visible: visible, toolHeight: 400))
        let card = placement.card.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY)
        XCTAssertEqual(card.width, 304)
        XCTAssertEqual(card.height, 400)
        XCTAssertTrue(visible.contains(card))
        XCTAssertFalse(card.intersects(anchor))
    }

    func testPopoverNearBottomRemainsInsideVisibleCanvas() throws {
        let visible = CGRect(x: 200, y: 400, width: 780, height: 560)
        let object = CGRect(x: 610, y: 880, width: 360, height: 200)
        let placement = try XCTUnwrap(WorkspacePouchPlacement(anchor: CGRect(x: object.maxX - 66, y: object.minY + 2, width: 28, height: 28), visible: visible, toolHeight: 520))
        XCTAssertTrue(visible.contains(placement.card.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY)))
        let folded = try XCTUnwrap(WorkspacePouchPlacement(anchor: CGRect(x: object.maxX - 66, y: object.minY + 2, width: 28, height: 28), visible: visible, toolHeight: 0))
        XCTAssertEqual(folded.frame.size, CGSize(width: 28, height: 28))
        XCTAssertTrue(folded.card.isEmpty)
    }

    func testPopoverGrowthPreservesItsOpeningEdgeAndDoesNotCoverItsTrigger() throws {
        let visible = CGRect(x: 0, y: 0, width: 900, height: 700)
        for y in [CGFloat(220), CGFloat(450)] {
            let anchor = CGRect(x: 700, y: y, width: 28, height: 28)
            let small = try XCTUnwrap(WorkspacePouchPlacement(anchor: anchor, visible: visible, toolHeight: 140))
            let large = try XCTUnwrap(WorkspacePouchPlacement(anchor: anchor, visible: visible, toolHeight: 900))
            let smallCard = small.card.offsetBy(dx: small.frame.minX, dy: small.frame.minY)
            let largeCard = large.card.offsetBy(dx: large.frame.minX, dy: large.frame.minY)
            if y < visible.midY { XCTAssertEqual(smallCard.minY, largeCard.minY) }
            else { XCTAssertEqual(smallCard.maxY, largeCard.maxY) }
            XCTAssertTrue(visible.contains(largeCard))
            XCTAssertFalse(largeCard.intersects(anchor))
        }
    }

    func testAnimatedCollapseAndRestoreTravelThroughIntermediateFrames() async throws {
        let h = try await FramedWorkspaceHarness(width: 1000, reduceMotion: false)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let editor = try await h.editor()
        h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        let pouch = try XCTUnwrap(h.requests.pouch)
        let original = h.window.frame
        var animationTime = 0.0
        pouch.snapshotAnimationTime = { animationTime }
        pouch.collapse()
        let shrinking = try XCTUnwrap(pouch.transition)
        XCTAssertFalse(h.window.isVisible)
        animationTime = 0.06; pouch.stepSnapshotAnimation()
        XCTAssertGreaterThan(shrinking.frame.width, original.width * 0.03)
        XCTAssertLessThan(shrinking.frame.width, original.width)
        animationTime = 0.2; pouch.stepSnapshotAnimation()
        XCTAssertNil(pouch.transition)
        XCTAssertTrue(try XCTUnwrap(pouch.panel).isVisible)
        pouch.restore()
        let expanding = try XCTUnwrap(pouch.transition)
        animationTime = 0.27; pouch.stepSnapshotAnimation()
        XCTAssertGreaterThan(expanding.frame.width, original.width * 0.03)
        XCTAssertLessThan(expanding.frame.width, original.width)
        animationTime = 0.4; pouch.stepSnapshotAnimation()
        XCTAssertNil(pouch.transition)
        XCTAssertEqual(h.window.alphaValue, 1)
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
    }
    func testInterruptedSnapshotAnimationCannotHideRestoredOrDetachedWindow() async throws {
        let h = try await FramedWorkspaceHarness(width: 1000, reduceMotion: false)
        defer { h.close() }
        h.window.makeKeyAndOrderFront(nil)
        let editor = try await h.editor()
        h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        let pouch = try XCTUnwrap(h.requests.pouch)
        var time = 0.0
        pouch.snapshotAnimationTime = { time }
        pouch.collapse()
        let shrinking = try XCTUnwrap(pouch.transition)
        time = 0.03; pouch.stepSnapshotAnimation()
        pouch.restore()
        XCTAssertFalse(shrinking.isVisible)
        XCTAssertFalse(pouch.transition === shrinking)
        time = 1; pouch.stepSnapshotAnimation()
        XCTAssertNil(pouch.transition)
        XCTAssertTrue(h.window.isVisible)
        XCTAssertEqual(h.window.alphaValue, 1)
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
        pouch.collapse()
        let interrupted = try XCTUnwrap(pouch.transition)
        pouch.detach()
        time = 2; pouch.stepSnapshotAnimation()
        XCTAssertFalse(interrupted.isVisible)
        XCTAssertNil(pouch.transition)
        XCTAssertNil(pouch.panel)
        XCTAssertEqual(h.window.alphaValue, 1)
    }

    func testFourEdgesUseNativeWindowGeometryAndChangeOrientation() {
        let window = CGRect(x: 100, y: 200, width: 1000, height: 700)
        let left = WorkspacePouchGeometry.dockedFrame(window: window, edge: .left, ratio: 0.5)
        let right = WorkspacePouchGeometry.dockedFrame(window: window, edge: .right, ratio: 0.5)
        let top = WorkspacePouchGeometry.dockedFrame(window: window, edge: .top, ratio: 0.5)
        let bottom = WorkspacePouchGeometry.dockedFrame(window: window, edge: .bottom, ratio: 0.5)
        XCTAssertEqual(left.minX, 108); XCTAssertEqual(right.maxX, 1092)
        XCTAssertEqual(top.maxY, 856); XCTAssertEqual(bottom.minY, 208)
        XCTAssertEqual(left.size, CGSize(width: 38, height: 236))
        XCTAssertEqual(top.size, CGSize(width: 236, height: 38))
        XCTAssertEqual(WorkspacePouchGeometry.nearestEdge(point: CGPoint(x: 500, y: 899), window: window), .top)
        XCTAssertEqual(WorkspacePouchGeometry.nearestEdge(point: CGPoint(x: 1095, y: 500), window: window), .right)
    }

    func testExplicitCollapseAndOrbRestoreKeepTheSameNativeEditor() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = SpatialWorkspaceController(defaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = BlockTextView(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
        editor.load(markdown: "Pouch synthetic text")
        window.contentView = editor; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let originalCloseAction = window.standardWindowButton(.closeButton)?.action
        let pouch = WorkspacePouchController(model: model, defaults: defaults)
        pouch.reduceMotion = true; pouch.attach(to: window)
        defer { pouch.detach(); window.contentView = nil; window.close() }
        let panel = try XCTUnwrap(pouch.panel)
        let start = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        pouch.beginDrag(at: start)
        pouch.updateDrag(to: CGPoint(x: start.x + 3, y: start.y))
        XCTAssertFalse(pouch.isDragging)
        pouch.updateDrag(to: CGPoint(x: 130, y: 500))
        XCTAssertFalse(pouch.isCollapsed); XCTAssertTrue(window.isVisible)
        pouch.collapse()
        XCTAssertTrue(pouch.isCollapsed); XCTAssertFalse(window.isVisible)
        _ = pouch.endDrag(at: CGPoint(x: 130, y: 500))
        XCTAssertEqual(panel.frame.size, CGSize(width: 44, height: 44))
        XCTAssertFalse(panel.hidesOnDeactivate, "The collapsed pouch must remain floating when another app is active")
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        pouch.restore()
        XCTAssertTrue(window.isVisible); XCTAssertFalse(pouch.isCollapsed)
        XCTAssertTrue(window.contentView === editor); XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))
        XCTAssertEqual(editor.serialize(), "Pouch synthetic text")
        pouch.detach()
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.action, originalCloseAction)
        XCTAssertNil(pouch.panel)
    }

    func testSpringSettlesWithoutOvershootAndStopsAtTheTarget() {
        var spring = WorkspaceSpringPoint(position: .zero)
        let target = CGPoint(x: 200, y: -130)
        var maximum: CGFloat = 0
        for _ in 0..<240 {
            spring.step(target: target, stiffness: 280, damping: 34, elapsed: 1 / 60)
            maximum = max(maximum, spring.position.x)
        }
        XCTAssertLessThanOrEqual(maximum, target.x + 0.001)
        XCTAssertEqual(spring.position.x, target.x, accuracy: 0.01)
        XCTAssertEqual(spring.position.y, target.y, accuracy: 0.01)
        XCTAssertTrue(spring.isSettled(at: target))
    }
}
