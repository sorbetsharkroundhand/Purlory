@testable import PurloryIntelligence
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class StoryMapControllerTests: XCTestCase {
    private func fixture() async throws -> LegacyBoundaryFixture {
        let f = try await LegacyBoundaryFixture(mode: .fiction)
        f.session.updateSelectedDocumentBody("# 밤\n원문 하나\n# 아침\n원문 둘\n")
        f.session.selectWorkspaceMode(.map)
        return f
    }
    func testPreparedMapAndCurrentSceneBelongToActualSelectedDocument() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let model = StoryMapController(session: f.session, observeEnergy: false, sleep: {})
        defer { model.stop() }
        model.update(); await model.waitForCurrentWork()
        let prepared = try XCTUnwrap(model.prepared)
        XCTAssertEqual(prepared.identity, f.session.runtimeIdentity)
        XCTAssertEqual(model.visibleRows.count, 2)
        let last = try XCTUnwrap(prepared.projection.scenes.last)
        model.notePosition(last.sourceRange.lowerBound, identity: prepared.identity)
        XCTAssertEqual(model.currentSceneID, last.id)
        model.notePosition(0, identity: .init(key: prepared.identity.key, generation: prepared.identity.generation + 1))
        XCTAssertNil(model.currentSceneID)
        model.filter(threadID: "missing", characterID: nil)
        XCTAssertTrue(model.visibleRows.isEmpty)
        model.filter(threadID: nil, characterID: nil)
        XCTAssertEqual(model.visibleRows.count, 2)
    }
    func testEditRetiresActionsSynchronouslyAndLatePreparationCannotReplaceCurrentSource() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let original = try XCTUnwrap(f.session.runtimeIdentity)
        let started = expectation(description: "Old Map suspended"), pause = AskTestPause(started)
        let model = StoryMapController(session: f.session, observeEnergy: false, sleep: {}, project: { input in
            let result = try await StoryMapProjection.build(input.document, knowledge: input.knowledge, knowledgeOrigin: input.knowledgeOrigin, order: input.order)
            if input.document.identity == original { await pause.run(emit: { _ in }) }
            return result
        })
        defer { model.stop() }
        model.update(); await fulfillment(of: [started], timeout: 2)
        f.session.updateSelectedDocumentBody("# 새 원고\n새로운 위치\n")
        XCTAssertNil(model.prepared); XCTAssertTrue(model.visibleRows.isEmpty)
        model.update(); await model.waitForCurrentWork()
        let current = try XCTUnwrap(model.prepared)
        XCTAssertEqual(current.identity, f.session.runtimeIdentity)
        XCTAssertEqual(current.projection.rows.first?.title, "새 원고")
        await pause.release(); await Task.yield()
        XCTAssertEqual(model.prepared, current)
    }
    func testDocumentABAAndLeavingMapInvalidateReadyActionsWithoutAutomaticWork() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let model = StoryMapController(session: f.session, observeEnergy: false, sleep: {})
        defer { model.stop() }
        model.update(); await model.waitForCurrentWork()
        let old = try XCTUnwrap(model.prepared), first = try XCTUnwrap(f.session.selectedDocumentID)
        let second = try XCTUnwrap(f.session.createDocument(title: "Other"))
        f.session.selectDocument(first); f.session.selectDocument(second); f.session.selectDocument(first)
        XCTAssertNil(model.prepared); XCTAssertTrue(model.visibleRows.isEmpty)
        XCTAssertNotEqual(f.session.runtimeIdentity, old.identity)
        model.update(); await model.waitForCurrentWork(); XCTAssertNotNil(model.prepared)
        f.session.selectWorkspaceMode(.write)
        XCTAssertNil(model.prepared); XCTAssertTrue(model.visibleRows.isEmpty)
        model.update(); await model.waitForCurrentWork(); XCTAssertNil(model.prepared)
    }
    func testForegroundAndPolicyPausePreparationAndOnlyResumeCurrentMap() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let model = StoryMapController(session: f.session, observeEnergy: false, sleep: {})
        defer { model.stop() }
        model.setForegroundBusy(true); model.setPolicyPaused(true); model.update()
        XCTAssertEqual(model.status, .paused); XCTAssertNil(model.prepared)
        model.setForegroundBusy(false); await model.waitForCurrentWork(); XCTAssertNil(model.prepared)
        model.setPolicyPaused(false); await model.waitForCurrentWork(); XCTAssertNotNil(model.prepared)
        model.setForegroundBusy(true); XCTAssertNil(model.prepared)
        f.session.selectWorkspaceMode(.write)
        model.setForegroundBusy(false); await model.waitForCurrentWork(); XCTAssertNil(model.prepared)
    }
    func testSelectedOrderSurvivesSnapshotRefreshAndActuallyReachesProjector() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let recorder = StoryMapOrderRecorder()
        let model = StoryMapController(session: f.session, observeEnergy: false, sleep: {}, project: { input in
            await recorder.record(input.order)
            return try await StoryMapProjection.build(input.document, order: input.order)
        })
        defer { model.stop() }
        model.setOrder(.chronology); model.update(); await model.waitForCurrentWork()
        XCTAssertEqual(model.order, .chronology)
        model.update(generation: 1); await model.waitForCurrentWork()
        let orders = await recorder.values
        XCTAssertEqual(orders, [.chronology, .chronology])
        model.setOrder(.manuscript); await model.waitForCurrentWork()
        XCTAssertEqual(model.order, .manuscript)
        let changed = await recorder.values; XCTAssertEqual(changed.last, .manuscript)
    }
    func testBackgroundMemoizationIsRawOriginalScopedAndBounded() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let document = try XCTUnwrap(f.session.selectedDocumentSnapshot), worker = StoryMapProjector()
        func input(_ doc: ProjectDocumentSnapshot) -> StoryMapInput {
            .init(document: doc, knowledge: nil, knowledgeOrigin: nil, knowledgeGeneration: 0, order: .manuscript)
        }
        let first = try await worker.project(input(document))
        let hit = try await worker.project(input(document)); XCTAssertEqual(first, hit)
        let count = await worker.buildCount; XCTAssertEqual(count, 1)
        for _ in 0..<2 {
            let next = ProjectDocumentSnapshot(identity: .init(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1),
                title: document.title, body: document.body, kind: .manuscript, mode: .fiction, userData: [:])
            _ = try await worker.project(input(next))
        }
        let retained = await worker.retainedCount; XCTAssertEqual(retained, 2)
        _ = try await worker.project(input(document))
        let rebuilt = await worker.buildCount; XCTAssertEqual(rebuilt, 4)
        let unicodeWorker = StoryMapProjector()
        for body in ["# 한\n원문", "# 한\n원문"] {
            let changed = ProjectDocumentSnapshot(identity: document.identity, title: document.title, body: body, kind: .manuscript, mode: .fiction, userData: [:])
            _ = try await unicodeWorker.project(input(changed))
        }
        let rawBuilds = await unicodeWorker.buildCount
        XCTAssertEqual(rawBuilds, 2, "Canonically equal strings still have different original revisions")
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await worker.project(input(document)) }
        do { _ = try await task.value; XCTFail("Cancelled cache hit must refuse") } catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
    }
    func testMemoizationCannotReuseFictionManuscriptActionsForAnotherModeOrKind() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let document = try XCTUnwrap(f.session.selectedDocumentSnapshot), worker = StoryMapProjector()
        func input(mode: WritingMode, kind: WritingDocument.Kind) -> StoryMapInput {
            .init(document: .init(identity: document.identity, title: document.title, body: document.body, kind: kind, mode: mode, userData: [:]),
                knowledge: nil, knowledgeOrigin: nil, knowledgeGeneration: 0, order: .manuscript)
        }
        _ = try await worker.project(input(mode: .fiction, kind: .manuscript))
        let general = try await worker.project(input(mode: .general, kind: .manuscript))
        let note = try await worker.project(input(mode: .fiction, kind: .note))
        XCTAssertTrue(general.rows.isEmpty); XCTAssertTrue(note.rows.isEmpty)
    }
    func testRetirementClearsActionsBeforeStatusObserversSeeTheRetiredState() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let model = StoryMapController(session: f.session, observeEnergy: false, sleep: {})
        defer { model.stop() }
        model.update(); await model.waitForCurrentWork()
        XCTAssertNotNil(model.prepared)
        let sub = model.$status.dropFirst().sink { _ in
            XCTAssertNil(model.prepared); XCTAssertTrue(model.visibleRows.isEmpty)
        }
        f.session.updateSelectedDocumentBody("# Changed\nChanged source")
        withExtendedLifetime(sub) {}
    }
}

private actor StoryMapOrderRecorder {
    var values: [StoryMapProjection.Order] = []
    func record(_ order: StoryMapProjection.Order) { values.append(order) }
}
