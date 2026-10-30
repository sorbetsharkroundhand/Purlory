@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class SpatialWorkspaceControllerTests: XCTestCase {
    func testWhisperTypingIgnoresSmallPointerMovement() {
        let model = SpatialWorkspaceController()
        model.noteTyping(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(model.whisperTyping)
        model.notePointer(at: CGPoint(x: 148, y: 100)); XCTAssertTrue(model.whisperTyping)
        model.notePointer(at: CGPoint(x: 149, y: 100)); XCTAssertFalse(model.whisperTyping)
    }
    func testDragThresholdAndCancellationRestoreTheExactOrigin() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = WritingDocumentID(), b = WritingDocumentID()
        let project = project([a, b])
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: project, selected: a)
        var split = model.layout; split.move(.document(b), to: .after(.document(a))); model.setLayout(split)
        let original = model.layout
        let geometry = SpatialWorkspaceGeometry(layout: original, viewport: CGSize(width: 1200, height: 700))
        model.beginDrag(.document(a), at: CGPoint(x: 400, y: 30))
        model.updateDrag(to: CGPoint(x: 404, y: 30), geometry: geometry)
        XCTAssertFalse(model.isDragging); XCTAssertEqual(model.layout, original)
        let destination = try XCTUnwrap(geometry.tiles[.document(b)])
        model.updateDrag(to: CGPoint(x: destination.midX, y: 600), geometry: geometry)
        XCTAssertTrue(model.isDragging); XCTAssertTrue(model.layout.contains(.document(a)))
        XCTAssertEqual(model.layout, original)
        XCTAssertEqual(model.presentationLayout, original)
        XCTAssertNotNil(model.previewTarget)
        model.cancelDrag()
        XCTAssertFalse(model.isDragging); XCTAssertNil(model.previewTarget)
        XCTAssertEqual(model.layout, original)
    }

    func testDropCommitsOnceAndPreferencesStayProjectScoped() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = WritingDocumentID(), b = WritingDocumentID(), first = project([a, b])
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: first, selected: a)
        var split = model.layout; split.move(.document(b), to: .after(.document(a))); model.setLayout(split)
        let geometry = SpatialWorkspaceGeometry(layout: model.layout, viewport: CGSize(width: 1200, height: 700))
        let target = try XCTUnwrap(geometry.tiles[.document(b)])
        model.beginDrag(.document(a), at: CGPoint(x: 400, y: 30))
        model.updateDrag(to: CGPoint(x: target.midX, y: target.maxY - 10), geometry: geometry)
        model.endDrag()
        XCTAssertEqual(model.layout.columns.last?.slots.map(\.tile), [.document(b), .document(a)])
        let afterDrop = SpatialWorkspaceController(defaults: defaults)
        afterDrop.configure(project: first, selected: a)
        XCTAssertEqual(afterDrop.layout, model.layout)
        model.toggle(.characters); model.toggle(.margin)
        let saved = model.layout
        let reopened = SpatialWorkspaceController(defaults: defaults)
        reopened.configure(project: first, selected: a)
        XCTAssertEqual(reopened.layout, saved)
        reopened.configure(project: project([a]), selected: a)
        XCTAssertFalse(reopened.layout.contains(.margin))
        model.beginDrag(.document(a), at: .zero)
        model.configure(project: project([b]), selected: b)
        model.endDrag()
        XCTAssertEqual(model.layout.openDocuments, [b])
    }

    func testGroupFramesRemainInvariantDuringDrag() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = WritingDocumentID(), b = WritingDocumentID(), c = WritingDocumentID()
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: project([a, b, c]), selected: a)
        var initialLayout = model.layout
        initialLayout.move(.document(b), to: .after(.document(a)))
        initialLayout.openDocument(c)
        initialLayout.move(.document(c), to: .below(.document(b)))
        model.setLayout(initialLayout)

        let viewport = CGSize(width: 1400, height: 800)
        let baseGeometry = SpatialWorkspaceGeometry(layout: model.layout, viewport: viewport)
        let initialColumns = baseGeometry.columns
        let initialTiles = baseGeometry.tiles

        let startRect = try XCTUnwrap(baseGeometry.tiles[.document(a)])
        model.beginDrag(.document(a), at: CGPoint(x: startRect.midX, y: startRect.minY + 16), initialFrame: startRect, baseGeometry: baseGeometry)

        let bRect = try XCTUnwrap(baseGeometry.tiles[.document(b)])
        let cRect = try XCTUnwrap(baseGeometry.tiles[.document(c)])
        let testPoints = [
            CGPoint(x: 12, y: 300),
            CGPoint(x: bRect.minX + 16, y: bRect.midY),
            CGPoint(x: bRect.midX, y: bRect.midY),
            CGPoint(x: bRect.midX, y: bRect.minY + 20),
            CGPoint(x: cRect.midX, y: cRect.maxY - 20),
            CGPoint(x: 1390, y: 300)
        ]

        for point in testPoints {
            model.updateDrag(to: point, geometry: baseGeometry)
            XCTAssertTrue(model.isDragging)
            XCTAssertEqual(model.layout, initialLayout)
            XCTAssertEqual(model.presentationLayout, initialLayout)
            let currentGeometry = SpatialWorkspaceGeometry(layout: model.presentationLayout, viewport: viewport)
            XCTAssertEqual(currentGeometry.columns, initialColumns)
            XCTAssertEqual(currentGeometry.tiles, initialTiles)
        }
        model.cancelDrag()
    }

    func testDropInGroupCenterMergesTileIntoGroup() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = WritingDocumentID(), b = WritingDocumentID()
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: project([a, b]), selected: a)
        var split = model.layout
        split.move(.document(b), to: .after(.document(a)))
        model.setLayout(split)
        XCTAssertEqual(model.layout.columns.count, 3)

        let geometry = SpatialWorkspaceGeometry(layout: model.layout, viewport: CGSize(width: 1200, height: 700))
        let sourceRect = try XCTUnwrap(geometry.tiles[.document(a)])
        let targetRect = try XCTUnwrap(geometry.tiles[.document(b)])

        model.beginDrag(.document(a), at: CGPoint(x: sourceRect.midX, y: sourceRect.minY + 16), initialFrame: sourceRect, baseGeometry: geometry)
        model.updateDrag(to: CGPoint(x: targetRect.midX, y: targetRect.midY), geometry: geometry)
        XCTAssertEqual(model.previewTarget, .tab(.document(b), index: 1))
        model.endDrag()

        XCTAssertEqual(model.layout.columns.count, 2, "Dropping in the center of another document group must merge into its binder without splitting a column")
        XCTAssertEqual(model.layout.slot(containing: .document(b))?.tabs, [b, a])
        XCTAssertEqual(model.layout.slot(containing: .document(b))?.tile, .document(a))
    }

    func testDropTargetHysteresisPreventsBoundaryJitter() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = WritingDocumentID(), b = WritingDocumentID()
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: project([a, b]), selected: a)
        var split = model.layout
        split.move(.document(b), to: .after(.document(a)))
        model.setLayout(split)

        let geometry = SpatialWorkspaceGeometry(layout: model.layout, viewport: CGSize(width: 1200, height: 700))
        let rect = try XCTUnwrap(geometry.tiles[.document(b)])
        let topBoundaryY = rect.minY + rect.height * 0.28

        model.beginDrag(.document(a), at: CGPoint(x: 300, y: 30), baseGeometry: geometry)
        // Enter center merge zone just below the 28% boundary
        model.updateDrag(to: CGPoint(x: rect.midX, y: topBoundaryY + 6), geometry: geometry)
        XCTAssertEqual(model.previewTarget, .tab(.document(b), index: 1))

        // Jitter ±4pt across the 28% boundary; hysteresis (10pt) must keep the center merge target stable
        for offset: CGFloat in [-2, -4, 1, -3, 2, -4] {
            model.updateDrag(to: CGPoint(x: rect.midX, y: topBoundaryY + offset), geometry: geometry)
            XCTAssertEqual(model.previewTarget, .tab(.document(b), index: 1), "Boundary jitter of \(offset)pt must not flip dropTarget")
        }

        // Moving well past hysteresis margin transitions cleanly to .above
        model.updateDrag(to: CGPoint(x: rect.midX, y: topBoundaryY - 14), geometry: geometry)
        XCTAssertEqual(model.previewTarget, .above(.document(b)))

        // Jitter ±4pt back toward center across the boundary keeps .above stable
        for offset: CGFloat in [2, 4, -1, 3, -2, 4] {
            model.updateDrag(to: CGPoint(x: rect.midX, y: topBoundaryY + offset), geometry: geometry)
            XCTAssertEqual(model.previewTarget, .above(.document(b)), "Boundary jitter of +\(offset)pt must not flip from .above")
        }
        model.cancelDrag()
    }

    func testDragCancellationAndInvalidDropRestoresOriginalLayout() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = WritingDocumentID(), b = WritingDocumentID()
        let proj = project([a, b])
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: proj, selected: a)
        var split = model.layout
        split.move(.document(b), to: .after(.document(a)))
        model.setLayout(split)
        let original = model.layout
        let geometry = SpatialWorkspaceGeometry(layout: original, viewport: CGSize(width: 1200, height: 700))
        let targetRect = try XCTUnwrap(geometry.tiles[.document(b)])

        // 1. Explicit cancelDrag after valid preview
        model.beginDrag(.document(a), at: CGPoint(x: 300, y: 30), baseGeometry: geometry)
        model.updateDrag(to: CGPoint(x: targetRect.midX, y: targetRect.minY + 20), geometry: geometry)
        XCTAssertEqual(model.previewTarget, .above(.document(b)))
        model.cancelDrag()
        XCTAssertEqual(model.layout, original)
        XCTAssertTrue(model.undoStack.isEmpty)

        // 2. Drop in an invalid region (outside canvas bounds) after visiting a spatial drop zone
        model.beginDrag(.document(a), at: CGPoint(x: 300, y: 30), baseGeometry: geometry)
        model.updateDrag(to: CGPoint(x: targetRect.midX, y: targetRect.minY + 20), geometry: geometry)
        XCTAssertEqual(model.previewTarget, .above(.document(b)))
        model.updateDrag(to: CGPoint(x: -200, y: -200), geometry: geometry)
        XCTAssertNil(model.previewTarget)
        model.endDrag()
        XCTAssertEqual(model.layout, original, "Dropping in an invalid region must not commit a stale spatial target")
        XCTAssertTrue(model.undoStack.isEmpty)

        // 3. Drop back onto the dragged tile's own frame (no-op)
        let sourceRect = try XCTUnwrap(geometry.tiles[.document(a)])
        model.beginDrag(.document(a), at: CGPoint(x: sourceRect.midX, y: sourceRect.minY + 16), baseGeometry: geometry)
        model.updateDrag(to: CGPoint(x: sourceRect.midX, y: sourceRect.midY), geometry: geometry)
        XCTAssertNil(model.previewTarget)
        model.endDrag()
        XCTAssertEqual(model.layout, original)
        XCTAssertTrue(model.undoStack.isEmpty)
    }

    func testLayoutCommitsOnlyOnDropConfirmation() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = WritingDocumentID(), b = WritingDocumentID()
        let proj = project([a, b])
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: proj, selected: a)
        var split = model.layout
        split.move(.document(b), to: .after(.document(a)))
        model.setLayout(split)
        let original = model.layout
        let key = "purlory.spatial-workspace.\(proj.id.rawValue.uuidString)"
        let initialSavedData = defaults.data(forKey: key)

        var commitCount = 0
        var reorderCount = 0
        model.onCommit = { _ in commitCount += 1 }
        model.onTileReorder = { _ in reorderCount += 1 }

        let geometry = SpatialWorkspaceGeometry(layout: original, viewport: CGSize(width: 1200, height: 700))
        let targetRect = try XCTUnwrap(geometry.tiles[.document(b)])

        model.beginDrag(.document(a), at: CGPoint(x: 300, y: 30), baseGeometry: geometry)
        model.updateDrag(to: CGPoint(x: targetRect.midX, y: targetRect.minY + 20), geometry: geometry)
        model.updateDrag(to: CGPoint(x: targetRect.maxX - 15, y: targetRect.midY), geometry: geometry)
        model.updateDrag(to: CGPoint(x: targetRect.midX, y: targetRect.maxY - 20), geometry: geometry)

        // Before endDrag(), model.layout, persistence, and undoStack must remain completely untouched
        XCTAssertEqual(model.layout, original)
        XCTAssertEqual(defaults.data(forKey: key), initialSavedData)
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(reorderCount, 0)
        XCTAssertTrue(model.undoStack.isEmpty)

        // Confirm drop
        model.endDrag()
        XCTAssertNotEqual(model.layout, original)
        XCTAssertEqual(model.layout.columns.last?.slots.map(\.tile), [.document(b), .document(a)])
        XCTAssertNotEqual(defaults.data(forKey: key), initialSavedData)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(reorderCount, 1)
        XCTAssertEqual(model.undoStack, [original])

        // Undo restores the exact pre-drop layout
        model.undoLayout()
        XCTAssertEqual(model.layout, original)
        XCTAssertTrue(model.canRedoLayout)
        model.redoLayout()
        XCTAssertEqual(model.layout.columns.last?.slots.map(\.tile), [.document(b), .document(a)])
    }

    private func project(_ ids: [WritingDocumentID]) -> WritingProject {
        WritingProject(id: WritingProjectID(), title: "Spatial fixture", mode: .general,
            documents: ids.map { WritingDocument(id: $0, title: $0.rawValue.uuidString, body: "fixture", kind: .manuscript) })
    }
}
