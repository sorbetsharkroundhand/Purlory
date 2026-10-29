import AppKit
import XCTest
@testable import PurloryCore

@MainActor
final class ProjectShutdownTests: XCTestCase {
    func testDirectProjectTerminationRejectsUnresolvedStartup() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let loading = ProjectSession(store: fixture.store, defaults: fixture.defaults)
        do { try await loading.flushForTermination(); XCTFail("Unresolved startup allowed shutdown") } catch {}
        XCTAssertEqual(loading.phase, .loading)
        XCTAssertFalse(loading.isTransitioning)
    }

    // Catches shutting resources down or replying before the last accepted project edit is durable.
    func testSuccessfulTerminationFlushesProjectBeforePositionsShutdownAndDrain() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        fixture.session.updateSelectedDocumentBody("last accepted sentence")
        var events: [String] = []
        let coordinator = ProjectTerminationCoordinator(
            session: fixture.session,
            persistPositions: { events.append("positions") },
            shutdown: { events.append("shutdown") },
            drain: {
                events.append("drain")
                let durable = try? await fixture.store.activeProject()
                XCTAssertEqual(durable?.documents[0].body, "last accepted sentence")
            })
        let result = await coordinator.prepareForTermination()
        XCTAssertEqual(result, .terminateNow)
        XCTAssertEqual(events, ["positions", "shutdown", "drain"])
        XCTAssertEqual(fixture.session.savePhase, .saved)
        fixture.session.updateSelectedDocumentBody("too late after shutdown")
        XCTAssertEqual(fixture.session.selectedDocument?.body, "last accepted sentence")
    }

    // Catches false success or irreversible shutdown after a project save failure.
    func testProjectSaveFailureCancelsTerminationAndKeepsEditableDirtyOwner() async throws {
        let fixture = try await LegacyBoundaryFixture(failProjectWrites: true)
        defer { fixture.cleanUp() }
        fixture.session.updateSelectedDocumentBody("unsaved latest sentence")
        var shutdown = false
        var drained = false
        let coordinator = ProjectTerminationCoordinator(
            session: fixture.session,
            persistPositions: {}, shutdown: { shutdown = true }, drain: { drained = true })
        let result = await coordinator.prepareForTermination()
        XCTAssertEqual(result, .terminateCancel)
        XCTAssertFalse(shutdown)
        XCTAssertFalse(drained)
        XCTAssertEqual(fixture.session.savePhase, .failed)
        XCTAssertEqual(fixture.session.selectedDocument?.body, "unsaved latest sentence")
        XCTAssertNotNil(fixture.session.lastErrorMessage)
        fixture.session.updateSelectedDocumentBody("still editable")
        XCTAssertEqual(fixture.session.selectedDocument?.body, "still editable")
        let durable = try await fixture.store.activeProject()
        XCTAssertEqual(durable?.documents[0].body, "original project")
    }

    // The production shutdown route writes the imported project, never the source archive.
    func testImportedLegacyTerminationSavesProjectAndPreservesSource() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        let source = fixture.legacyRoot.appendingPathComponent("entries.json")
        let bytes = Data(#"{"entries":[{"id":"00000000-0000-0000-0000-000000000101","title":"Legacy","body":"legacy original","createdAt":"2026-09-01T00:00:00Z"}]}"#.utf8)
        try bytes.write(to: source)
        let result = try await ImportProjectCoordinator(store: fixture.store, session: fixture.session)
            .importLegacy(from: source, mode: .general, title: "Imported")
        fixture.session.updateSelectedDocumentBody("latest project sentence")
        let coordinator = ProjectTerminationCoordinator(session: fixture.session,
            persistPositions: {}, shutdown: {}, drain: {})
        let response = await coordinator.prepareForTermination()
        XCTAssertEqual(response, .terminateNow)
        fixture.session.updateSelectedDocumentBody("too late")
        XCTAssertEqual(fixture.session.selectedDocument?.body, "latest project sentence")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let durable = try await fixture.store.activeProject()
        XCTAssertEqual(durable?.id, result.projectID)
        XCTAssertEqual(durable?.documents[0].body, "latest project sentence")
    }

    // A failed project save replies once, preserves editing and supports retry.
    func testProjectFailureRepliesFalseOnceAndAllowsRetry() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        fixture.session.updateSelectedDocumentBody("retain project edits")
        let projectFolder = fixture.root.appendingPathComponent("Projects/" + fixture.project.id.rawValue.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: projectFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectFolder.path) }
        var shutdowns = 0
        let coordinator = ProjectTerminationCoordinator(session: fixture.session,
            persistPositions: {}, shutdown: { shutdowns += 1 }, drain: {})
        let cancelled = expectation(description: "Save failure cancels quit")
        var replies: [Bool] = []
        XCTAssertEqual(coordinator.requestTermination { replies.append($0); cancelled.fulfill() }, .terminateLater)
        XCTAssertEqual(coordinator.requestTermination { _ in XCTFail("Duplicate termination reply") }, .terminateLater)
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(shutdowns, 0)
        XCTAssertEqual(fixture.session.selectedDocument?.body, "retain project edits")
        XCTAssertTrue(fixture.session.isEditorEditable)
        XCTAssertNotNil(fixture.session.lastErrorMessage)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectFolder.path)
        let retried = expectation(description: "Retry succeeds")
        XCTAssertEqual(coordinator.requestTermination { replies.append($0); retried.fulfill() }, .terminateLater)
        await fulfillment(of: [retried], timeout: 3)
        XCTAssertEqual(replies, [false, true])
        XCTAssertEqual(shutdowns, 1)
        let durable = try await fixture.store.activeProject()
        XCTAssertEqual(durable?.documents[0].body, "retain project edits")
    }

    // Catches launching a second save/shutdown task while AppKit waits for the engine to drain.
    func testRepeatedTerminationRequestsShareOneTaskAndOneReply() async throws {
        let fixture = try await LegacyBoundaryFixture()
        defer { fixture.cleanUp() }
        fixture.session.updateSelectedDocumentBody("durable once")
        let started = expectation(description: "Drain starts")
        let replied = expectation(description: "AppKit reply")
        let gate = AsyncStream<Void>.makeStream()
        var shutdowns = 0
        var replies = 0
        let coordinator = ProjectTerminationCoordinator(
            session: fixture.session,
            persistPositions: {}, shutdown: { shutdowns += 1 }, drain: {
                started.fulfill()
                for await _ in gate.stream { break }
            })
        XCTAssertEqual(coordinator.requestTermination { success in
            XCTAssertTrue(success); replies += 1; replied.fulfill()
        }, .terminateLater)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(coordinator.requestTermination { _ in XCTFail("Duplicate reply") }, .terminateLater)
        gate.continuation.yield(())
        gate.continuation.finish()
        await fulfillment(of: [replied], timeout: 3)
        XCTAssertEqual(shutdowns, 1)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(coordinator.requestTermination { _ in XCTFail("Reply after approved termination") }, .terminateLater)
    }
}
