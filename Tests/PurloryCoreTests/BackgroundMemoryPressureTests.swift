@_spi(Benchmark) @testable import PurloryInference
import Combine
import XCTest
@testable import PurloryCore

@MainActor
final class BackgroundMemoryPressureTests: XCTestCase {
    func testPressureCancelsHydrationAndLateResultCannotPublish() async {
        let document = fixture()
        let started = expectation(description: "Sidecar read suspended")
        let persistence = PressureSidecarPersistence(started: started)
        let reader = makeReader(document, persistence)
        defer { reader.shutdown() }
        reader.noteDocumentChange(document)
        await fulfillment(of: [started], timeout: 1)
        let retiredGeneration = reader.hydrateGeneration
        reader.setMemoryPressurePaused(true)
        XCTAssertGreaterThan(reader.hydrateGeneration, retiredGeneration)
        let late = expectation(description: "Cancelled hydration must not publish")
        late.isInverted = true
        let subscription = reader.$snapshotGeneration.dropFirst().sink { _ in late.fulfill() }
        await persistence.release()
        await fulfillment(of: [late], timeout: 0.1)
        XCTAssertNil(reader.snapshot)
        withExtendedLifetime(subscription) {}
    }

    func testPausedEditsManualRebuildAndRecoveryDoNotReadOrEraseCaches() async {
        let document = fixture()
        let forbidden = expectation(description: "Pressure must not read, reset, or reload")
        forbidden.isInverted = true
        let persistence = PressureSidecarPersistence(forbidden: forbidden)
        let reader = makeReader(document, persistence)
        defer { reader.shutdown() }
        reader.setMemoryPressurePaused(true)
        reader.originalNameAnchorsEnabled = true
        reader.noteDocumentChange(document)
        reader.rehydrate(entryID: document.identity.key.documentID.rawValue)
        reader.requestPass()
        reader.requestFullPass()
        XCTAssertFalse(reader.isIndexing)
        guard case .blocked = reader.manualPhase else { return XCTFail("Manual request needs pressure state") }
        XCTAssertNil(reader.originalNameAnchors)
        reader.setForegroundCompletionBusy(false)
        reader.setMemoryPressurePaused(false)
        XCTAssertEqual(reader.manualPhase, .idle)
        await fulfillment(of: [forbidden], timeout: 0.3)
        let counts = await persistence.counts
        XCTAssertEqual(counts, [0, 0, 0])
        XCTAssertNil(reader.originalNamePreparation.scope, "Normal alone cannot restart optional preparation")
    }

    func testPressureRetainsPublishedKnowledgeAndAllowsAnExplicitLaterEdit() async {
        let document = fixture()
        let persistence = PressureSidecarPersistence()
        let reader = makeReader(document, persistence)
        defer { reader.shutdown() }
        let hydrated = expectation(description: "Initial knowledge published")
        let initial = reader.$snapshotGeneration.dropFirst().prefix(1).sink { _ in hydrated.fulfill() }
        reader.noteDocumentChange(document)
        await fulfillment(of: [hydrated], timeout: 1)
        initial.cancel()
        let generation = reader.snapshotGeneration
        let scope = reader.snapshot?.storyMemory?.scope
        reader.setMemoryPressurePaused(true)
        XCTAssertEqual(reader.snapshotGeneration, generation)
        XCTAssertEqual(reader.snapshot?.storyMemory?.scope, scope)
        reader.setMemoryPressurePaused(false)
        let refreshed = expectation(description: "Explicit edit can refresh knowledge")
        let later = reader.$snapshotGeneration.dropFirst().prefix(1).sink { _ in refreshed.fulfill() }
        reader.rehydrate(entryID: document.identity.key.documentID.rawValue)
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(reader.snapshotGeneration, generation + 1)
        withExtendedLifetime(later) {}
    }

    private func fixture() -> ProjectDocumentSnapshot {
        .init(identity: .init(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1),
              title: "Fixture", body: "# Fixture\nA fictional visitor waited at the gate.", kind: .manuscript, mode: .fiction)
    }
    private func makeReader(_ document: ProjectDocumentSnapshot, _ persistence: PressureSidecarPersistence) -> BackgroundIndexer {
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        reader.attach(documentProvider: { document })
        return reader
    }
}

private actor PressureSidecarPersistence: KnowledgeSidecarPersisting {
    let started: XCTestExpectation?
    let forbidden: XCTestExpectation?
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var counts = [0, 0, 0]
    init(started: XCTestExpectation? = nil, forbidden: XCTestExpectation? = nil) {
        self.started = started; self.forbidden = forbidden
    }
    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar {
        counts[0] += 1
        forbidden?.fulfill()
        if let started, counts[0] == 1 {
            await withCheckedContinuation { continuation in self.continuation = continuation; started.fulfill() }
        }
        return KnowledgeSidecar(scope: scope)
    }
    func release() { continuation?.resume(); continuation = nil }
    func save(_ sidecar: KnowledgeSidecar, pruningTo liveHashes: Set<String>?, scope: StoryMemoryScope) async throws {
        counts[1] += 1; forbidden?.fulfill()
    }
    func replaceWithFresh(scope: StoryMemoryScope, generation: Int) async throws -> KnowledgeSidecar {
        counts[2] += 1; forbidden?.fulfill(); return KnowledgeSidecar(scope: scope)
    }
    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {}
}
