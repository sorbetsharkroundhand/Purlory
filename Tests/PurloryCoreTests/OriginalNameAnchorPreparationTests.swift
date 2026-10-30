@testable import PurloryIntelligence
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class OriginalNameAnchorPreparationTests: XCTestCase {
    @MainActor
    func testLatePreparationCannotPublishAcrossAToBToA() async {
        let started = expectation(description: "First preparation paused")
        let gate = AnchorBuildBarrier(started: started)
        let preparation = OriginalNameAnchorPreparation(delay: .zero, gate: { true }, build: { request, previous in
            let index = try OriginalNameAnchorIndex.make(body: request.body, documentID: request.documentID,
                characters: request.characters, previous: previous)
            await gate.waitFirst()
            return index
        })
        defer { preparation.shutdown() }
        let id = WritingDocumentID(), a = WritingProjectID(), b = WritingProjectID()
        let card = CharacterCard(name: "유정")
        func prepare(_ project: WritingProjectID, _ generation: UInt64, _ text: String) {
            preparation.prepare(body: text, documentID: id.rawValue,
                scope: .project(projectID: project, documentID: id),
                runtimeIdentity: ProjectRuntimeIdentity(key: .init(projectID: project, documentID: id), generation: generation),
                characters: [card])
        }
        prepare(a, 1, "유정은 첫 열쇠를 받았다.\n유정은")
        await fulfillment(of: [started], timeout: 1)
        prepare(b, 2, "유정은 다른 열쇠를 받았다.\n유정은")
        prepare(a, 3, "유정은 새 열쇠를 받았다.\n유정은")
        let published = expectation(description: "Current A generation published")
        let subscription = preparation.$index.compactMap { $0 }.prefix(1).sink { _ in published.fulfill() }
        await fulfillment(of: [published], timeout: 1)
        XCTAssertEqual(preparation.runtimeIdentity?.generation, 3)
        let stale = expectation(description: "Retired A cannot publish")
        stale.isInverted = true
        let oldSubscription = preparation.$index.dropFirst().sink { _ in stale.fulfill() }
        await gate.release()
        await fulfillment(of: [stale], timeout: 0.1)
        XCTAssertEqual(preparation.runtimeIdentity?.generation, 3)
        let body = "유정은 새 열쇠를 받았다.\n유정은"
        XCTAssertEqual(preparation.index?.latest(in: "유정은", startingAt: body.utf16.count - 3)?.evidence.quote, "유정은 새 열쇠를 받았다.")
        withExtendedLifetime((subscription, oldSubscription)) {}
    }

    @MainActor
    func testForegroundCancelsPreparationAndResumeRetriesPendingInput() async {
        let started = expectation(description: "Background preparation suspended")
        let gate = AnchorBuildBarrier(started: started)
        let preparation = OriginalNameAnchorPreparation(delay: .zero, gate: { true }, build: { request, previous in
            let index = try OriginalNameAnchorIndex.make(body: request.body, documentID: request.documentID,
                characters: request.characters, previous: previous)
            await gate.waitFirst()
            return index
        })
        defer { preparation.shutdown() }
        let id = UUID()
        preparation.prepare(body: "유정은 열쇠를 받았다.\n유정은", documentID: id,
            scope: .legacy(documentID: .init(rawValue: id)), runtimeIdentity: nil,
            characters: [CharacterCard(name: "유정")])
        await fulfillment(of: [started], timeout: 1)
        preparation.setForegroundBusy(true)
        await gate.release()
        let blocked = expectation(description: "Busy foreground prevents publication")
        blocked.isInverted = true
        let pending = preparation.$index.compactMap { $0 }.sink { _ in blocked.fulfill() }
        await fulfillment(of: [blocked], timeout: 0.1)
        pending.cancel()
        let resumed = expectation(description: "Pending input retries without another edit")
        let subscription = preparation.$index.compactMap { $0 }.prefix(1).sink { _ in resumed.fulfill() }
        preparation.setForegroundBusy(false)
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(preparation.index?.documentID, id)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testPowerGateAndShutdownKeepOptionalWorkQuiet() async {
        let invoked = expectation(description: "Blocked preparation must not run")
        invoked.isInverted = true
        let preparation = OriginalNameAnchorPreparation(delay: .zero, gate: { false }, build: { request, _ in
            invoked.fulfill()
            return try OriginalNameAnchorIndex.make(body: request.body, documentID: request.documentID, characters: request.characters)
        })
        let id = UUID()
        preparation.prepare(body: "유정은 왔다.", documentID: id,
            scope: .legacy(documentID: .init(rawValue: id)), runtimeIdentity: nil,
            characters: [CharacterCard(name: "유정")])
        preparation.setForegroundBusy(false)
        preparation.shutdown()
        await fulfillment(of: [invoked], timeout: 0.1)
        XCTAssertNil(preparation.index)
        XCTAssertNil(preparation.scope)
    }
}

private actor AnchorBuildBarrier {
    let started: XCTestExpectation
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func waitFirst() async {
        calls += 1
        guard calls == 1 else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
