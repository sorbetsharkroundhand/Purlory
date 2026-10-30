@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class SpatialBinderTests: XCTestCase {
    func testOpeningDocumentsStacksInOneSlotAndReopeningSelectsExistingTab() {
        let a = WritingDocumentID(), b = WritingDocumentID(), c = WritingDocumentID()
        var layout = SpatialWorkspaceLayout(documents: [a], selected: a, navigatorVisible: false)
        layout.openDocument(b)
        layout.openDocument(c)
        XCTAssertEqual(layout.columns.count, 1)
        XCTAssertEqual(layout.openDocuments, [a, b, c])
        XCTAssertEqual(layout.tiles, [.document(c)])
        layout.openDocument(a)
        XCTAssertEqual(layout.columns.count, 1)
        XCTAssertEqual(layout.openDocuments, [a, b, c])
        XCTAssertEqual(layout.tiles, [.document(a)])
    }

    func testClosingActiveTabSelectsNeighborWithoutRemovingBinder() {
        let a = WritingDocumentID(), b = WritingDocumentID(), c = WritingDocumentID()
        var layout = SpatialWorkspaceLayout(documents: [a], selected: a, navigatorVisible: false)
        layout.openDocument(b); layout.openDocument(c)
        XCTAssertTrue(layout.close(.document(b)))
        XCTAssertEqual(layout.tiles, [.document(c)])
        XCTAssertTrue(layout.close(.document(c)))
        XCTAssertEqual(layout.tiles, [.document(a)])
        XCTAssertFalse(layout.close(.document(a)))
    }

    func testLegacySlotDecodingAndTabRoundTrip() throws {
        struct LegacySlot: Encodable { let tile: WorkspaceTileID; let weight: Double }
        let a = WritingDocumentID(), b = WritingDocumentID()
        let old = try JSONEncoder().encode(LegacySlot(tile: .document(a), weight: 0.4))
        let slot = try JSONDecoder().decode(SpatialWorkspaceSlot.self, from: old)
        XCTAssertEqual(slot.tabs, [a]); XCTAssertEqual(slot.weight, 0.4)
        var layout = SpatialWorkspaceLayout(documents: [a, b], selected: b)
        layout.openDocument(a)
        XCTAssertEqual(try JSONDecoder().decode(SpatialWorkspaceLayout.self, from: JSONEncoder().encode(layout)), layout)
    }

    func testNormalizationKeepsSurvivingHiddenTabsAndDropsDuplicates() {
        let a = WritingDocumentID(), b = WritingDocumentID(), c = WritingDocumentID()
        var layout = SpatialWorkspaceLayout(documents: [], selected: nil, navigatorVisible: false)
        layout.columns = [
            .init(slots: [.init(tile: .document(a), tabs: [a, b, b]), .init(tile: .characters, tabs: [c])]),
            .init(slots: [.init(tile: .document(b), tabs: [b, c])])]
        layout.normalize(validDocuments: [b, c])
        XCTAssertEqual(layout.openDocuments, [b, c])
        XCTAssertEqual(layout.tiles, [.document(b), .characters, .document(c)])
        XCTAssertEqual(layout.slot(containing: .characters)?.tabs, [])
    }

    func testReorderTearOffAndMergePreserveEveryDocument() {
        let a = WritingDocumentID(), b = WritingDocumentID(), c = WritingDocumentID()
        var layout = SpatialWorkspaceLayout(documents: [a, b], selected: a, navigatorVisible: false)
        layout.openDocument(c)
        layout.move(.document(a), to: .tab(.document(c), index: 3))
        XCTAssertEqual(layout.openDocuments, [b, c, a])
        layout.move(.document(c), to: .after(.document(b)))
        XCTAssertEqual(layout.columns.count, 2)
        XCTAssertEqual(layout.slot(containing: .document(b))?.tabs, [b, a])
        XCTAssertEqual(layout.slot(containing: .document(c))?.tabs, [c])
        layout.move(.document(c), to: .tab(.document(b), index: 1))
        XCTAssertEqual(layout.columns.count, 1)
        XCTAssertEqual(layout.openDocuments, [b, c, a])
        XCTAssertEqual(layout.tiles, [.document(c)])
        layout.move(.document(c), to: .below(.document(b)))
        XCTAssertEqual(layout.columns[0].slots.count, 2)
        XCTAssertEqual(Set(layout.openDocuments), [a, b, c])
    }
}

@MainActor final class SpatialBinderControllerTests: XCTestCase {
    func testLeavingDocumentListDropRegionDoesNotCloseTab() {
        let a = WritingDocumentID(), b = WritingDocumentID()
        let project = WritingProject(id: WritingProjectID(), title: "List return", mode: .general,
            documents: [a, b].map { .init(id: $0, title: "Fixture", body: "", kind: .manuscript) })
        let suite = "purlory.binder-test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: project, selected: a)
        let origin = model.layout
        let geometry = SpatialWorkspaceGeometry(layout: origin, viewport: .init(width: 1000, height: 700))
        model.beginDrag(.document(a), at: .zero)
        model.updateDrag(to: .init(x: 100, y: 100), geometry: geometry, tabTarget: .documentList)
        XCTAssertTrue(model.isDocumentListDrop)
        model.updateDrag(to: .init(x: -500, y: -500), geometry: geometry)
        XCTAssertNil(model.previewTarget)
        model.endDrag()
        XCTAssertEqual(model.layout, origin, "Only a release inside the list can close a tab")
        var reorderCount = 0
        model.onTileReorder = { _ in reorderCount += 1 }
        model.beginDrag(.document(b), at: .zero)
        model.updateDrag(to: .init(x: 500, y: 20), geometry: geometry, tabTarget: .tab(.document(a), index: 0))
        model.updateDrag(to: .init(x: -500, y: -500), geometry: geometry)
        model.endDrag()
        XCTAssertEqual(model.layout.openDocuments, [b, a])
        XCTAssertEqual(reorderCount, 0, "A remembered tab proposal must still only change presentation order")
    }

    func testTrashingADocumentDuringDragCannotRestoreItsTab() {
        let a = WritingDocumentID(), b = WritingDocumentID()
        var project = WritingProject(id: WritingProjectID(), title: "Binders", mode: .general,
            documents: [a, b].map { .init(id: $0, title: "Fixture", body: "", kind: .manuscript) })
        let suite = "purlory.binder-test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: project, selected: a)
        let geometry = SpatialWorkspaceGeometry(layout: model.layout, viewport: .init(width: 1000, height: 700))
        model.beginDrag(.document(b), at: .zero)
        model.updateDrag(to: .init(x: 900, y: 300), geometry: geometry)
        project.trashedDocumentIDs.insert(b)
        model.configure(project: project, selected: a); model.endDrag()
        XCTAssertEqual(model.layout.openDocuments, [a])
        XCTAssertFalse(model.isDragging)
    }

    func testCanceledTabMoveDoesNotPersistAndProjectSwitchRejectsOldDrag() throws {
        let a = WritingDocumentID(), b = WritingDocumentID(), c = WritingDocumentID()
        let project = WritingProject(id: WritingProjectID(), title: "Binders", mode: .general,
            documents: [a, b, c].map { .init(id: $0, title: "Fixture", body: "", kind: .manuscript) })
        let suite = "purlory.binder-test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: project, selected: a); model.open(c)
        let origin = model.layout
        let geometry = SpatialWorkspaceGeometry(layout: origin, viewport: .init(width: 1200, height: 700))
        let saved = defaults.data(forKey: "purlory.spatial-workspace.\(project.id.rawValue.uuidString)")
        model.beginDrag(.document(c), at: .zero)
        model.updateDrag(to: .init(x: 600, y: 20), geometry: geometry, tabTarget: .tab(.document(a), index: 0))
        XCTAssertTrue(model.isTabDrop)
        model.updateDrag(to: .init(x: 1000, y: 300), geometry: geometry)
        XCTAssertFalse(model.isTabDrop)
        XCTAssertEqual(defaults.data(forKey: "purlory.spatial-workspace.\(project.id.rawValue.uuidString)"), saved)
        model.cancelDrag(); XCTAssertEqual(model.layout, origin)
        model.beginDrag(.document(c), at: .zero)
        model.updateDrag(to: .init(x: 600, y: 20), geometry: geometry, tabTarget: .tab(.document(a), index: 0))
        model.endDrag()
        XCTAssertEqual(model.layout.openDocuments, [c, a, b])
        let restored = SpatialWorkspaceController(defaults: defaults)
        restored.configure(project: project, selected: c)
        XCTAssertEqual(restored.layout, model.layout)
        model.beginDrag(.document(c), at: .zero)
        model.updateDrag(to: .init(x: 1000, y: 300), geometry: geometry)
        let d = WritingDocumentID()
        let next = WritingProject(id: WritingProjectID(), title: "Next", mode: .general,
            documents: [.init(id: d, title: "Next", body: "", kind: .manuscript)])
        model.configure(project: next, selected: d); model.endDrag()
        XCTAssertEqual(model.layout.openDocuments, [d])
        XCTAssertFalse(model.isDragging)
    }

    func testOpeningUsesActiveBinderAndReopeningRevealsHiddenTab() {
        let a = WritingDocumentID(), b = WritingDocumentID(), c = WritingDocumentID(), d = WritingDocumentID()
        let project = WritingProject(id: WritingProjectID(), title: "Binders", mode: .general,
            documents: [a, b, c, d].map { .init(id: $0, title: "Fixture", body: "", kind: .manuscript) })
        let suite = "purlory.binder-test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SpatialWorkspaceController(defaults: defaults)
        model.configure(project: project, selected: a)
        var split = model.layout
        split.move(.document(b), to: .end)
        model.setLayout(split)
        model.open(c)
        XCTAssertEqual(model.layout.slot(containing: .document(a))?.tabs, [a, c])
        model.open(a)
        XCTAssertTrue(model.layout.tiles.contains(.document(a)))
        model.configure(project: project, selected: d)
        XCTAssertEqual(model.layout.slot(containing: .document(a))?.tabs, [a, c, d])
        XCTAssertEqual(model.layout.columns.count, 3)
    }
}
