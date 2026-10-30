@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class DocumentOutlineControllerTests: XCTestCase {
    func testCurrentHeadingRequiresPreparedIdentityAndClearsUnprovenPosition() async throws {
        let snapshot = outlineSnapshot(body: "intro\n# One\nbody\n## Two\nlast")
        let controller = DocumentOutlineController(observeEnergy: false, sleep: {})
        controller.update(snapshot); await controller.waitForCurrentWork()
        let headings = try XCTUnwrap(controller.prepared?.projection.headings)
        controller.notePosition(headings[1].id + 1, identity: snapshot.identity)
        XCTAssertEqual(controller.currentHeadingID, headings[1].id)
        controller.notePosition(0, identity: snapshot.identity)
        XCTAssertNil(controller.currentHeadingID)
        controller.notePosition(headings[0].id, identity: snapshot.identity)
        XCTAssertEqual(controller.currentHeadingID, headings[0].id)
        controller.notePosition(headings[1].id, identity: outlineSnapshot().identity)
        XCTAssertNil(controller.currentHeadingID)
        controller.notePosition(nil, identity: snapshot.identity)
        XCTAssertNil(controller.currentHeadingID)
        controller.stop()
    }

    func testStaleABAAndMetadataGenerationsCannotPublish() async throws {
        let gate = OutlinePreparationGate()
        let controller = DocumentOutlineController(observeEnergy: false, sleep: {}, project: { try await gate.project($0) })
        let a = outlineSnapshot(body: "# A"), b = outlineSnapshot(body: "# B")
        controller.update(a); await gate.waitForCount(1)
        let oldA = try XCTUnwrap(controller.workTask)
        controller.update(b); await gate.waitForCount(2)
        let oldB = try XCTUnwrap(controller.workTask)
        let newest = outlineSnapshot(key: a.identity.key, generation: 3, body: a.body)
        controller.update(newest); await gate.waitForCount(3)
        try await gate.finish(0); await oldA.value
        XCTAssertNil(controller.prepared)
        try await gate.finish(2); await controller.waitForCurrentWork()
        XCTAssertEqual(controller.prepared?.identity, newest.identity)
        XCTAssertEqual(controller.prepared?.projection.headings.first?.title, "A")
        try await gate.finish(1); await oldB.value
        XCTAssertEqual(controller.prepared?.identity, newest.identity)
        controller.stop()
    }

    func testForegroundAndPolicyPauseRetireWorkAndResumeLatestSnapshot() async throws {
        let gate = OutlinePreparationGate()
        let controller = DocumentOutlineController(observeEnergy: false, sleep: {}, project: { try await gate.project($0) })
        let snapshot = outlineSnapshot()
        controller.update(snapshot); await gate.waitForCount(1)
        let old = try XCTUnwrap(controller.workTask)
        controller.setForegroundBusy(true); controller.setPolicyPaused(true)
        try await gate.finish(0); await old.value
        XCTAssertNil(controller.prepared)
        XCTAssertEqual(controller.status, .paused)
        controller.setForegroundBusy(false)
        XCTAssertNil(controller.workTask)
        controller.setPolicyPaused(false); await gate.waitForCount(2)
        try await gate.finish(1); await controller.waitForCurrentWork()
        XCTAssertEqual(controller.prepared?.identity, snapshot.identity)
        XCTAssertEqual(controller.status, .idle)
        controller.stop()
    }

    func testStopAndReentryRejectOldWorkAndClearSelection() async throws {
        let gate = OutlinePreparationGate()
        let controller = DocumentOutlineController(observeEnergy: false, sleep: {}, project: { try await gate.project($0) })
        controller.update(outlineSnapshot(body: "# Old")); await gate.waitForCount(1)
        let old = try XCTUnwrap(controller.workTask)
        controller.stop()
        try await gate.finish(0); await old.value
        XCTAssertNil(controller.prepared)
        XCTAssertNil(controller.currentHeadingID)
        let next = outlineSnapshot(body: "# New")
        controller.update(next); await gate.waitForCount(2)
        try await gate.finish(1); await controller.waitForCurrentWork()
        XCTAssertEqual(controller.prepared?.identity, next.identity)
        controller.update(nil)
        XCTAssertNil(controller.prepared)
        controller.stop()
    }

    func testProviderFailureLeavesWritingIndependentAndNewInputCanRecover() async throws {
        let controller = DocumentOutlineController(observeEnergy: false, sleep: {}, project: { snapshot in
            if snapshot.body == "broken" { throw OutlineTestError.failed }
            return try await DocumentOutlineProjection.build(snapshot.body)
        })
        controller.update(outlineSnapshot(body: "broken")); await controller.waitForCurrentWork()
        XCTAssertNil(controller.prepared)
        XCTAssertEqual(controller.status, .unavailable)
        controller.update(outlineSnapshot(body: "# Recovered")); await controller.waitForCurrentWork()
        XCTAssertEqual(controller.prepared?.projection.headings.first?.title, "Recovered")
        controller.stop()
    }
}

private enum OutlineTestError: Error { case failed }
private actor OutlinePreparationGate {
    private var requests: [(ProjectDocumentSnapshot, CheckedContinuation<DocumentOutlineProjection, Error>)] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func project(_ snapshot: ProjectDocumentSnapshot) async throws -> DocumentOutlineProjection {
        try await withCheckedThrowingContinuation { continuation in
            requests.append((snapshot, continuation))
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            for waiter in ready { waiter.1.resume() }
        }
    }
    func waitForCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ index: Int) async throws {
        let request = requests[index]
        let result = try await DocumentOutlineProjection.build(request.0.body)
        request.1.resume(returning: result)
    }
}
