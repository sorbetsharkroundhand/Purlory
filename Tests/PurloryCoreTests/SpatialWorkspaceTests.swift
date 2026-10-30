@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class SpatialWorkspaceTests: XCTestCase {
    private let a = WritingDocumentID(), b = WritingDocumentID(), c = WritingDocumentID()

    func testOpenDocumentsAndToolsShareColumnsWithoutDuplicateTiles() {
        var layout = SpatialWorkspaceLayout(documents: [a, b, c], selected: a)
        XCTAssertEqual(layout.openDocuments, [a, b])
        XCTAssertEqual(layout.columns.first?.width, 204)
        layout.openDocument(c); layout.openDocument(c)
        layout.toggle(.characters); layout.toggle(.narrative); layout.toggle(.margin)
        XCTAssertEqual(layout.openDocuments, [a, b, c])
        XCTAssertEqual(layout.columns.last?.slots.map(\.tile), [.characters, .narrative, .margin])
        XCTAssertEqual(layout.columns.last?.width, 256)
        XCTAssertEqual(Set(layout.tiles).count, layout.tiles.count)
        XCTAssertEqual(layout.columns.last!.slots.reduce(0) { $0 + $1.weight }, 1, accuracy: 0.0001)
    }

    func testCloseLastDocumentIsRejectedButClosingNeverDeletesOtherTiles() {
        var layout = SpatialWorkspaceLayout(documents: [a, b], selected: a)
        XCTAssertTrue(layout.close(.document(a)))
        XCTAssertFalse(layout.close(.document(b)))
        XCTAssertEqual(layout.openDocuments, [b])
        XCTAssertTrue(layout.tiles.contains(.navigator))
        layout.openAll([a, b, c]); layout.openAll([a, b, c])
        XCTAssertEqual(layout.openDocuments, [b, a, c])
    }

    func testEveryDropDirectionRetainsUniqueTilesAndNormalizesRows() {
        for target in [SpatialDropTarget.start, .end, .before(.document(b)),
                       .after(.document(b)), .above(.document(b)), .below(.document(b))] {
            var layout = SpatialWorkspaceLayout(documents: [a, b, c], selected: a)
            layout.openAll([a, b, c])
            layout.openDocument(c); layout.move(.document(a), to: target)
            XCTAssertEqual(Set(layout.tiles), [.navigator, .document(a), .document(b), .document(c)])
            XCTAssertEqual(layout.tiles.count, 4)
            for column in layout.columns {
                XCTAssertEqual(column.slots.reduce(0) { $0 + $1.weight }, 1, accuracy: 0.0001)
                XCTAssertTrue(column.slots.allSatisfy { $0.weight.isFinite && $0.weight > 0 })
            }
            if target == .above(.document(b)) {
                XCTAssertEqual(layout.columns.first { $0.slots.contains { $0.tile == .document(b) } }?.slots.map(\.tile),
                               [.document(a), .document(b)])
            }
            if target == .below(.document(b)) {
                XCTAssertEqual(layout.columns.first { $0.slots.contains { $0.tile == .document(b) } }?.slots.map(\.tile),
                               [.document(b), .document(a)])
            }
        }
    }

    func testRowResizePreservesOtherRowsAndClampsTheAdjacentPair() {
        var layout = SpatialWorkspaceLayout(documents: [a, b, c], selected: a, navigatorVisible: false)
        layout.move(.document(b), to: .below(.document(a)))
        layout.openDocument(c); layout.move(.document(c), to: .below(.document(b)))
        let unchanged = layout.columns[0].slots[0].weight
        let combined = layout.columns[0].slots[1].weight + layout.columns[0].slots[2].weight
        layout.resizeRows(column: 0, row: 1, delta: 10_000, height: 600)
        XCTAssertEqual(layout.columns[0].slots[0].weight, unchanged)
        XCTAssertEqual(layout.columns[0].slots[1].weight, combined * 0.8, accuracy: 0.0001)
        XCTAssertEqual(layout.columns[0].slots[2].weight, combined * 0.2, accuracy: 0.0001)
        layout.equalizeRows(column: 0, row: 1)
        XCTAssertEqual(layout.columns[0].slots[0].weight, unchanged)
        XCTAssertEqual(layout.columns[0].slots[1].weight, combined / 2, accuracy: 0.0001)
        XCTAssertEqual(layout.columns[0].slots[2].weight, combined / 2, accuracy: 0.0001)
    }

    func testWidthBoundsArePanelSpecificAndRejectNonfiniteInput() {
        var layout = SpatialWorkspaceLayout(documents: [a], selected: a)
        layout.toggle(.characters)
        layout.setColumnWidth(0, width: 5); XCTAssertEqual(layout.columns[0].width, 165)
        layout.setColumnWidth(0, width: 900); XCTAssertEqual(layout.columns[0].width, 320)
        layout.setColumnWidth(1, width: 5); XCTAssertEqual(layout.columns[1].width, 260)
        layout.setColumnWidth(1, width: 9000); XCTAssertEqual(layout.columns[1].width, 1600)
        layout.setColumnWidth(2, width: 5); XCTAssertEqual(layout.columns[2].width, 210)
        layout.setColumnWidth(2, width: 900); XCTAssertEqual(layout.columns[2].width, 420)
        layout.setColumnWidth(2, width: .nan); XCTAssertEqual(layout.columns[2].width, 420)
    }

    func testTileReadingOrderOnlyReordersOpenDocumentPositions() {
        let closed = WritingDocumentID()
        var layout = SpatialWorkspaceLayout(documents: [a, b], selected: a)
        layout.move(.document(b), to: .before(.document(a)))
        XCTAssertEqual(layout.reorderedDocuments([a, closed, b, c]), [b, closed, a, c])
    }

    func testGeometryUsesSourceSpacingAndKeepsOverflowReachable() throws {
        var layout = SpatialWorkspaceLayout(documents: [a, b], selected: a)
        layout.move(.document(b), to: .after(.document(a)))
        let geometry = SpatialWorkspaceGeometry(layout: layout, viewport: CGSize(width: 1200, height: 700))
        XCTAssertEqual(try XCTUnwrap(geometry.tiles[.navigator]).width, 204)
        XCTAssertEqual(try XCTUnwrap(geometry.tiles[.document(a)]).width, 482, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(geometry.tiles[.document(a)]).minX, 220, accuracy: 0.01)
        layout.move(.document(b), to: .below(.document(a)))
        let stacked = SpatialWorkspaceGeometry(layout: layout, viewport: CGSize(width: 500, height: 150))
        let first = try XCTUnwrap(stacked.tiles[.document(a)]), second = try XCTUnwrap(stacked.tiles[.document(b)])
        XCTAssertGreaterThanOrEqual(first.height, 95)
        XCTAssertEqual(second.minY - first.maxY, 8, accuracy: 0.01)
        XCTAssertGreaterThan(stacked.contentSize.height, 150)
        XCTAssertGreaterThanOrEqual(stacked.contentSize.width, 480)
        XCTAssertEqual(stacked.tiles.count, 3)
    }

    func testDropHitTestingUsesEdgeBandsAndTwentyEightPercentRows() throws {
        var layout = SpatialWorkspaceLayout(documents: [a, b], selected: a)
        layout.move(.document(b), to: .after(.document(a)))
        let geometry = SpatialWorkspaceGeometry(layout: layout, viewport: CGSize(width: 1200, height: 700))
        let rect = try XCTUnwrap(geometry.tiles[.document(b)])
        XCTAssertEqual(geometry.dropTarget(at: CGPoint(x: 12, y: 300), dragging: .document(a)), .start)
        XCTAssertEqual(geometry.dropTarget(at: CGPoint(x: 1190, y: 300), dragging: .document(a)), .end)
        XCTAssertEqual(geometry.dropTarget(at: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.27), dragging: .document(a)), .above(.document(b)))
        XCTAssertEqual(geometry.dropTarget(at: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.73), dragging: .document(a)), .below(.document(b)))
        XCTAssertEqual(geometry.dropTarget(at: CGPoint(x: rect.minX + 40, y: rect.midY), dragging: .document(a)), .before(.document(b)))
        XCTAssertEqual(geometry.dropTarget(at: CGPoint(x: rect.maxX - 40, y: rect.midY), dragging: .document(a)), .after(.document(b)))
        XCTAssertEqual(geometry.dropTarget(at: CGPoint(x: rect.midX, y: rect.midY), dragging: .document(a)), .tab(.document(b), index: 1))
        XCTAssertNil(geometry.dropTarget(at: CGPoint(x: 600, y: -100), dragging: .document(a)))
    }

    func testMalformedRestorationCannotDuplicateOrLoseTheLastRealDocument() {
        var layout = SpatialWorkspaceLayout(documents: [a, b], selected: a)
        layout.move(.document(b), to: .after(.document(a)))
        layout.columns[0].slots.append(.init(tile: .document(a), weight: .nan))
        layout.columns[1].slots[0].weight = -10
        layout.columns[2].width = .infinity
        layout.normalize(validDocuments: [a])
        XCTAssertEqual(layout.openDocuments, [a])
        XCTAssertEqual(Set(layout.tiles).count, layout.tiles.count)
        XCTAssertTrue(layout.columns.allSatisfy { $0.width == nil || $0.width!.isFinite })
        XCTAssertTrue(layout.columns.flatMap(\.slots).allSatisfy { $0.weight.isFinite && $0.weight > 0 })
    }
}
