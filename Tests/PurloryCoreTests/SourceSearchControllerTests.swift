@testable import PurloryIntelligence
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class SourceSearchControllerTests: XCTestCase {
    func testNewerQueryWinsAfterNoncooperativeOldSearchReturnsLate() async throws {
        let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
        let identity = try XCTUnwrap(f.session.runtimeIdentity)
        let started = expectation(description: "Original query paused")
        let barrier = SourceQueryBarrier(started: started)
        let model = SourceSearchController(session: f.session, origin: identity, cursor: 0, delay: .zero,
            build: { input in
                let hits = try SourceSearch.results(query: input.query, in: input.project,
                    origin: input.origin.key.documentID, cursor: input.cursor, scope: input.scope)
                await barrier.waitFirst(); return hits
            })
        defer { model.dismiss() }
        model.search(query: "original", scope: .project)
        await fulfillment(of: [started], timeout: 2)
        let published = expectation(description: "New query published")
        let sub = model.$hits.filter { $0.first?.matchedText == "project" }.prefix(1).sink { _ in published.fulfill() }
        model.search(query: "project", scope: .here)
        await fulfillment(of: [published], timeout: 2)
        let stale = expectation(description: "Old query stays retired"); stale.isInverted = true
        let retired = model.$hits.dropFirst().sink { _ in stale.fulfill() }
        await barrier.release()
        await fulfillment(of: [stale], timeout: 0.1)
        XCTAssertEqual(model.hits.first?.matchedText, "project")
        XCTAssertFalse(model.isSearching)
        withExtendedLifetime((sub, retired)) {}
    }

    func testDocumentABAAndBodyChangesInvalidateAllPendingResults() async throws {
        let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
        let first = try XCTUnwrap(f.session.selectedDocumentID)
        let second = try XCTUnwrap(f.session.createDocument(title: "Other"))
        f.session.selectDocument(first)
        let started = expectation(description: "A search paused"), barrier = SourceQueryBarrier(started: started)
        let model = SourceSearchController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity),
            cursor: 0, delay: .zero, build: { input in
                let hits = try SourceSearch.results(query: input.query, in: input.project,
                    origin: input.origin.key.documentID, cursor: input.cursor, scope: input.scope)
                await barrier.waitFirst(); return hits
            })
        defer { model.dismiss() }
        model.search(query: "project", scope: .project)
        await fulfillment(of: [started], timeout: 2)
        f.session.selectDocument(second); f.session.selectDocument(first)
        XCTAssertTrue(model.isInvalidated); XCTAssertTrue(model.hits.isEmpty)
        await barrier.release()
        let stale = expectation(description: "A generation cannot republish"); stale.isInverted = true
        let sub = model.$hits.filter { !$0.isEmpty }.sink { _ in stale.fulfill() }
        await fulfillment(of: [stale], timeout: 0.1)
        let edited = SourceSearchController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), cursor: 0, delay: .zero)
        defer { edited.dismiss() }
        f.session.updateSelectedDocumentBody("new writing")
        XCTAssertTrue(edited.isInvalidated); XCTAssertTrue(edited.hits.isEmpty)
        withExtendedLifetime(sub) {}
    }

    func testEmptyQueryAndDismissRetireNoncooperativePendingWork() async throws {
        for closes in [false, true] {
            let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
            let started = expectation(description: "Pending search"), barrier = SourceQueryBarrier(started: started)
            let model = SourceSearchController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity),
                cursor: 0, delay: .zero, build: { input in
                    let hits = try SourceSearch.results(query: input.query, in: input.project,
                        origin: input.origin.key.documentID, cursor: input.cursor, scope: input.scope)
                    await barrier.waitFirst(); return hits
                })
            defer { model.dismiss() }
            model.search(query: "original", scope: .project)
            await fulfillment(of: [started], timeout: 2)
            if closes { model.dismiss() } else { model.search(query: " ", scope: .here) }
            XCTAssertFalse(model.isSearching); XCTAssertTrue(model.hits.isEmpty)
            let stale = expectation(description: "Retired work stays silent"); stale.isInverted = true
            let sub = model.$hits.filter { !$0.isEmpty }.sink { _ in stale.fulfill() }
            await barrier.release(); await fulfillment(of: [stale], timeout: 0.1)
            withExtendedLifetime(sub) {}
        }
    }

    func testScopesWorkWithoutModelAndDismissAndEmptyQueryClearResults() async throws {
        let f = try await LegacyBoundaryFixture(); defer { f.cleanUp() }
        f.session.updateSelectedDocumentBody("# Part\n## One\n### Here\nneedle here\n### Next\nneedle next\n## Two\nneedle other")
        let model = SourceSearchController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity),
            cursor: 30, delay: .zero)
        defer { model.dismiss() }
        for (scope, count) in [(SourceSearchScope.here, 1), (.chapter, 2), (.project, 3)] {
            let ready = expectation(description: "Scope \(scope)")
            let sub = model.$hits.filter { $0.count == count }.prefix(1).sink { _ in ready.fulfill() }
            model.search(query: "needle", scope: scope)
            await fulfillment(of: [ready], timeout: 2)
            XCTAssertEqual(model.hits.count, count)
            withExtendedLifetime(sub) {}
        }
        model.search(query: " \n ", scope: .project)
        XCTAssertTrue(model.hits.isEmpty); XCTAssertFalse(model.isSearching)
        model.dismiss(); model.search(query: "needle", scope: .project)
        XCTAssertTrue(model.hits.isEmpty); XCTAssertTrue(model.isInvalidated)
    }
}

private actor SourceQueryBarrier {
    let started: XCTestExpectation
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func waitFirst() async {
        calls += 1
        guard calls == 1 else { return }
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}
