@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class EntryStoreUndoContractTests: XCTestCase {
    /// 이벤트 루프를 돌리지 않아야 Task로 미룬 복원·역등록을 즉시 검출한다.
    @MainActor
    private func withStore(_ body: (EntryStore, UndoManager, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-undo-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EntryStore(directory: root, autosaveDelay: .seconds(3600))
        let manager = UndoManager()
        manager.groupsByEvent = false
        store.structureUndoManager = manager
        defer {
            store.flush()
            manager.removeAllActions()
            try? FileManager.default.removeItem(at: root)
        }
        try body(store, manager, root)
    }

    @MainActor
    private func assertPersisted(_ expected: JournalEntry, in root: URL) throws {
        let reloaded = EntryStore(directory: root, autosaveDelay: .seconds(3600))
        let actual = try XCTUnwrap(reloaded.activeEntry)
        // ISO 8601 저장은 날짜의 소수 초를 버리므로 원고·변경 필드를 비교한다.
        XCTAssertEqual(actual.id, expected.id)
        XCTAssertEqual(actual.body, expected.body)
        XCTAssertEqual(actual.kind, expected.kind)
        XCTAssertEqual(actual.characters, expected.characters)
    }

    @MainActor
    func testStructureUndoRedoRestoresSynchronouslyAcrossRepeatedCycles() throws {
        try withStore { store, manager, root in
            let id = store.activeID
            store.updateActiveBody("마지막까지 보존할 원고.")
            store.flush()
            let before = try XCTUnwrap(store.activeEntry)

            manager.beginUndoGrouping()
            store.setKind(.novel, for: id)
            manager.endUndoGrouping()
            let after = try XCTUnwrap(store.activeEntry)
            XCTAssertEqual(after.resolvedKind, .novel)

            for _ in 0..<3 {
                XCTAssertTrue(manager.canUndo)
                store.structureUndoManager = nil
                manager.undo()
                XCTAssertEqual(store.activeEntry, before)
                XCTAssertTrue(store.structureUndoManager === manager)
                XCTAssertTrue(manager.canRedo, "undo 반환 전에 redo가 등록되어야 한다")
                try assertPersisted(before, in: root)

                store.structureUndoManager = nil
                manager.redo()
                XCTAssertEqual(store.activeEntry, after)
                XCTAssertTrue(store.structureUndoManager === manager)
                XCTAssertTrue(manager.canUndo, "redo 반환 전에 다음 undo가 등록되어야 한다")
                try assertPersisted(after, in: root)
            }
        }
    }

    @MainActor
    func testDebouncedCardBurstUndoRedoRestoresAndSavesSynchronously() throws {
        try withStore { store, manager, root in
            let id = store.activeID
            store.updateActiveBody("인물 소개와 별개로 보존할 본문.")
            var card = CharacterCard(name: "한결", note: "주인공")
            manager.beginUndoGrouping()
            store.upsertCharacter(card, in: id)
            manager.endUndoGrouping()
            manager.removeAllActions()
            let before = try XCTUnwrap(store.activeEntry)

            manager.beginUndoGrouping()
            card.name = "한결이"
            store.upsertCharacter(card, in: id)
            card.name = "한결이다"
            store.upsertCharacter(card, in: id)
            store.flush()
            manager.endUndoGrouping()
            let after = try XCTUnwrap(store.activeEntry)
            XCTAssertEqual(after.characters?.first?.name, "한결이다")

            store.structureUndoManager = nil
            manager.undo()
            XCTAssertEqual(store.activeEntry, before, "버스트 전체를 한 번에 복원해야 한다")
            XCTAssertTrue(store.structureUndoManager === manager)
            XCTAssertFalse(manager.canUndo, "타이핑마다 별도 undo가 남으면 안 된다")
            XCTAssertTrue(manager.canRedo)
            try assertPersisted(before, in: root)

            store.structureUndoManager = nil
            manager.redo()
            XCTAssertEqual(store.activeEntry, after)
            XCTAssertTrue(store.structureUndoManager === manager)
            try assertPersisted(after, in: root)
        }
    }
}
