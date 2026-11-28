import AppKit
import Combine
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import PurloryCore
@testable import PurloryDocumentEngine
@_spi(Benchmark) @testable import PurloryInference
@testable import PurloryIntelligence
@testable import PurloryKoreanBackend
@testable import PurloryWorkspaceUI

final class P0Cluster2SafetyTests: XCTestCase {

    // MARK: - 1. Future Knowledge Leakage in knowledgeChrono

    func testKnowledgeChronoExcludesCurrentSceneAndFutureFlashbackScenes() {
        let body = """
        # 1장
        지훈은 낡은 열쇠를 서랍에서 발견했다. 서랍은 굳게 잠겨 있었고 먼지가 두껍게 앉아 있었다.

        # 2장
        지훈은 어린 시절의 골목을 떠올렸다. 어둑한 골목 끝에서 누군가 이름을 부르는 소리가 들려왔다.

        # 3장
        십 년 전 그날 밤, 서연이 금고 비밀번호를 바꿨다는 사실이 뒤늦게 밝혀졌다.
        """
        let outline = DocumentOutline.parse(body)
        XCTAssertEqual(outline.scenes.count, 3)

        let h1 = outline.scenes[0].contentHash
        let h2 = outline.scenes[1].contentHash
        let h3 = outline.scenes[2].contentHash

        let jihun = CharacterCard(name: "지훈")
        let insights: [String: SceneInsights] = [
            h1: SceneInsights(knowledge: [
                KnowledgeDelta(characterID: jihun.id, stance: .knows, fact: "열쇠를 발견했다", sceneHash: h1)
            ]),
            h2: SceneInsights(knowledge: [
                KnowledgeDelta(characterID: jihun.id, stance: .knows, fact: "현재 씬 후반부 비밀", sceneHash: h2)
            ]),
            h3: SceneInsights(knowledge: [
                KnowledgeDelta(characterID: jihun.id, stance: .knows, fact: "미래 원고의 회상 비밀", sceneHash: h3)
            ]),
        ]
        let segments: [String: SceneSegmentation] = [
            h2: SceneSegmentation(segments: [
                NarrativeSegment(
                    sceneHash: h2,
                    localStart: 0,
                    localEnd: outline.scenes[1].utf16Range.count,
                    startQuote: "지훈은 어린 시절의 골목을 떠올렸다",
                    layer: .flashback,
                    depth: 1,
                    subjectCharacter: "지훈"
                )
            ])
        ]
        // Scene 3 occurs AFTER the cursor in discourse, even though it is marked as an earlier flashback.
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(),
            outline: outline,
            summariesByHash: [:],
            insights: insights,
            segments: segments,
            characters: [jihun],
            overrides: NarrativeOverrides([
                NarrativeOverride(kind: .sceneType, key: h3, value: "회상")
            ])
        )

        let cursorInScene2 = outline.scenes[1].utf16Range.lowerBound + 10
        let chronoKnown = snapshot.knowledgeChrono(of: jihun.id, atSceneContaining: cursorInScene2)
        let facts = Set(chronoKnown.map(\.fact))
        XCTAssertTrue(facts.contains("열쇠를 발견했다"), "Earlier scene written before cursor should remain visible")
        XCTAssertFalse(facts.contains("현재 씬 후반부 비밀"), "Current scene post-cursor delta must not leak")
        XCTAssertFalse(facts.contains("미래 원고의 회상 비밀"), "Future scene in discourse must never leak even if marked flashback")

        var report: [ContextReport.Item] = []
        let position = snapshot.position(at: cursorInScene2)
        let block = ContextAssembler.knowledgeText(
            snapshot,
            before: outline.scenes[1].utf16Range.lowerBound,
            position: position,
            controls: .init(nil),
            report: &report
        )
        XCTAssertFalse(block.contains("현재 씬 후반부 비밀"), "Prompt block must exclude current-scene delta")
        XCTAssertFalse(block.contains("미래 원고의 회상 비밀"), "Prompt block must exclude future flashback delta")
    }

    // MARK: - 2. ModelDownloadManager.refresh must not fail installed models under low power

    @MainActor
    func testModelDownloadManagerRefreshVerifiesInstalledModelDuringLowPower() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-P0-Refresh-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pin = ModelInstallManifest(
            id: "fixture/model",
            revision: String(repeating: "a", count: 40),
            files: ["config.json", "tokenizer.json", "model.safetensors"].map {
                .init(
                    path: $0,
                    size: 3,
                    digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                    algorithm: .sha256
                )
            }
        )
        let store = ModelInstallationStore(root: root)
        _ = try await store.install(pin) { _, _, destination in
            try Data("abc".utf8).write(to: destination)
        }

        let manager = ModelDownloadManager(
            store: store,
            manifestForID: { $0 == pin.id ? pin : nil },
            download: { _, _, destination in try Data("abc".utf8).write(to: destination) },
            startBlock: { "저전력 모드 중에는 내려받지 않아요" }
        )

        let done = expectation(description: "Installed model verifies as downloaded even in low power")
        let sub = manager.$states
            .compactMap { $0[pin.id] }
            .filter { $0 != .verifying }
            .prefix(1)
            .sink { state in
                XCTAssertEqual(state, .downloaded)
                done.fulfill()
            }
        manager.refresh([pin.id])
        await fulfillment(of: [done], timeout: 3)
        withExtendedLifetime(sub) {}

        // Starting a new download must still respect startBlock.
        let uncachedPin = ModelInstallManifest(id: "fixture/other", revision: pin.revision, files: pin.files)
        let blockedManager = ModelDownloadManager(
            store: store,
            manifestForID: { $0 == uncachedPin.id ? uncachedPin : nil },
            download: { _, _, _ in XCTFail("Download must not start when blocked") },
            startBlock: { "저전력 모드 중에는 내려받지 않아요" }
        )
        blockedManager.download(uncachedPin.id)
        XCTAssertEqual(blockedManager.states[uncachedPin.id], .failed("저전력 모드 중에는 내려받지 않아요"))
    }

    // MARK: - 3. KoreanNativeWorker retains freshly opened handle across normal cancelPending

    func testKoreanNativeWorkerRetainsOpenedHandleAfterCancelPending() async throws {
        let factory = RetainmentTestKoreanFactory()
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: factory)

        let first = Task { try await worker.analyze("첫 문장") }
        await fulfillment(of: [factory.openEntered], timeout: 3)
        worker.cancelPending()
        factory.allowOpenFinish.signal()

        do {
            _ = try await first.value
            XCTFail("Cancelled call must not publish")
        } catch {
            XCTAssertEqual(error as? KoreanNativeError, .cancelled)
        }

        // Subsequent analysis must reuse the already opened handle without re-opening.
        let second = try await worker.analyze("다음 문장")
        XCTAssertEqual(second.tokens.count, 1)
        let snapshotBeforeRelease = factory.snapshot()
        XCTAssertEqual(snapshotBeforeRelease.opened, 1, "cancelPending must not destroy a freshly initialized handle")
        XCTAssertEqual(snapshotBeforeRelease.closed, 0)

        await worker.release()
        let snapshotAfterRelease = factory.snapshot()
        XCTAssertEqual(snapshotAfterRelease.closed, 1)
    }

    // MARK: - 4. BackgroundIndexer foreground yield & resignActive observer teardown

    @MainActor
    func testBackgroundIndexerYieldsToForegroundCompletionAndRemovesObserverOnShutdown() async {
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 1),
            title: "Draft",
            body: "# 1장\n충분히 긴 장면 본문입니다. 백그라운드 인덱서가 처리할 내용이 여기에 들어 있습니다.",
            kind: .manuscript,
            mode: .fiction
        )
        let passStarted = expectation(description: "Pass entered persistence load")
        let persistence = YieldTestPersistence(passStarted: passStarted)
        let settings = CompletionSettings(defaults: UserDefaults(suiteName: "Purlory.P0Cluster2.\(UUID().uuidString)")!)
        settings.autocompleteEnabled = false
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        indexer.attach(documentProvider: { document })

        indexer.requestPass()
        await fulfillment(of: [passStarted], timeout: 3)
        XCTAssertTrue(indexer.isIndexing)
        let generationBeforeYield = indexer.passGeneration

        indexer.setForegroundCompletionBusy(true)
        XCTAssertFalse(indexer.isIndexing, "Foreground Ghost busy must immediately yield active indexing")
        XCTAssertGreaterThan(indexer.passGeneration, generationBeforeYield)

        await persistence.release()
        indexer.setForegroundCompletionBusy(false)
        indexer.shutdown()

        let loadsAfterShutdown = await persistence.loadCount
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        let loadsAfterNotification = await persistence.loadCount
        XCTAssertEqual(loadsAfterNotification, loadsAfterShutdown, "shutdown() must remove didResignActive observer")
    }

    @MainActor
    func testBackgroundIndexerResumesPendingIdleAndHydrationAfterForegroundCompletion() async throws {
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 1),
            title: "Draft",
            body: "# Chapter\nThe lighthouse keeper locks the door for the night.",
            kind: .manuscript,
            mode: .fiction
        )
        let hydrateStarted = expectation(description: "Initial hydration began")
        let persistence = YieldTestPersistence(passStarted: hydrateStarted)
        let settings = CompletionSettings(defaults: UserDefaults(suiteName: "Purlory.P0Cluster2.Resume.\(UUID().uuidString)")!)
        settings.autocompleteEnabled = true
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        defer { indexer.shutdown() }
        // Gate inference off while observing real timer scheduling and hydration.
        indexer._testGateStateProvider = { (.critical, false) }
        indexer.attach(documentProvider: { document })

        indexer.noteDocumentChange(document)
        await fulfillment(of: [hydrateStarted], timeout: 3)

        indexer.setForegroundCompletionBusy(true)
        await persistence.release()
        let generationAfterYield = indexer.passGeneration

        indexer.setForegroundCompletionBusy(false)

        // Wait up to 6.5s for both restarted hydration and the 5s fast idle pass.
        var hydrated = false
        var resumedPass = false
        for _ in 0..<65 {
            hydrated = indexer.snapshot != nil
            resumedPass = indexer.passGeneration > generationAfterYield
            if hydrated && resumedPass { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(hydrated, "Canceled hydration must restart when foreground completion becomes idle")
        XCTAssertTrue(resumedPass, "Pending idle indexing must resume after foreground completion finishes")
    }

    @MainActor
    func testBackgroundIndexerRetainsResignActiveObserverAfterMemoryPressureRecovery() async throws {
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 1),
            title: "Draft",
            body: "# Chapter\nThe lighthouse keeper locks the door for the night.",
            kind: .manuscript,
            mode: .fiction
        )
        let persistence = YieldTestPersistence(passStarted: nil)
        let settings = CompletionSettings(defaults: UserDefaults(suiteName: "Purlory.P0Cluster2.Pressure.\(UUID().uuidString)")!)
        settings.autocompleteEnabled = true
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        defer { indexer.shutdown() }
        indexer._testGateStateProvider = { (.critical, false) }
        indexer.attach(documentProvider: { document })

        indexer.setMemoryPressurePaused(true)
        let generationWhilePaused = indexer.passGeneration
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(indexer.passGeneration, generationWhilePaused, "Deactivation must not start a pass while memory pressure is active")

        indexer.setMemoryPressurePaused(false)
        let generationAfterRecovery = indexer.passGeneration
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<20 {
            if indexer.passGeneration > generationAfterRecovery { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(
            indexer.passGeneration,
            generationAfterRecovery,
            "Deactivation observer must still fire after recovering from memory pressure"
        )

        indexer.shutdown()
        let generationAfterShutdown = indexer.passGeneration
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(indexer.passGeneration, generationAfterShutdown, "Terminal shutdown() must remove the deactivation observer")
    }

    // MARK: - 5. CompletionEngine.instructPromptCost handles MLXLMCommon.TokenizerError.missingChatTemplate

    func testInstructPromptCostFallsBackOnMLXLMCommonMissingChatTemplate() {
        let cost = CompletionEngine.instructPromptCost(
            system: "sys",
            user: "usr",
            applyChatTemplate: { throw MLXLMCommon.TokenizerError.missingChatTemplate },
            encode: { Array(0..<$0.count) }
        )
        XCTAssertEqual(cost, ("sys\n\nusr").count)
        XCTAssertNotEqual(cost, .max)
    }

    // MARK: - 6. PromptCacheBox.commit runs copyPrefix outside NSLock so invalidate never deadlocks

    func testPromptCacheBoxCommitDoesNotHoldLockDuringCopyPrefix() {
        // Verify that invalidate() called from inside copyPrefix() succeeds without deadlocking
        // and prevents the stale snapshot from being stored as pinned.
        let model = NSObject()
        var boxRef: PromptCacheBox?
        let box = PromptCacheBox(
            maxPinnedTokens: 64,
            maxPinnedBytes: 1024,
            copyPrefix: { layers, count, _ in
                boxRef?.invalidate()
                return layers.map { _ in
                    let copy = KVCacheSimple()
                    copy.offset = count
                    return copy
                }
            }
        )
        boxRef = box
        let owner = PromptCacheBox.Owner(
            modelID: "m",
            modelIdentity: ObjectIdentifier(model),
            parameters: GenerateParameters()
        )
        let cache = KVCacheSimple()
        let reuse = box.begin(owner: owner, tokens: [1, 2, 3, 4], pinTokens: [1, 2]) { [cache] }
        XCTAssertNotNil(reuse)
        cache.offset = 4
        if let lease = reuse?.lease {
            // Would deadlock if commit() held NSLock across copyPrefix().
            box.commit(lease: lease)
        }
        // Because invalidate() bumped the epoch during copyPrefix(), a subsequent begin must not reuse any stale pin.
        let next = box.begin(owner: owner, tokens: [1, 2, 9, 10], pinTokens: [1, 2]) { [KVCacheSimple()] }
        XCTAssertEqual(next?.reusedTokens, 0)
    }
}

private final class RetainmentTestKoreanFactory: KoreanNativeFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    private var closed = 0
    let openEntered = XCTestExpectation(description: "open entered")
    let allowOpenFinish = DispatchSemaphore(value: 0)

    func open(resources: URL, admission: @Sendable () -> Bool) throws -> any KoreanNativeHandle {
        let shouldWait: Bool = lock.withLock {
            opened += 1
            return opened == 1
        }
        if shouldWait {
            openEntered.fulfill()
            allowOpenFinish.wait()
        }
        return Handle(factory: self)
    }

    func recordClose() { lock.withLock { closed += 1 } }
    func snapshot() -> (opened: Int, closed: Int) { lock.withLock { (opened, closed) } }

    private final class Handle: KoreanNativeHandle {
        let factory: RetainmentTestKoreanFactory
        init(factory: RetainmentTestKoreanFactory) { self.factory = factory }
        func analyze(_ text: String, admission: @Sendable () -> Bool) throws -> KoreanNativeAnalysis {
            let range = NSRange(location: 0, length: text.utf16.count)
            return KoreanNativeAnalysis(
                tokens: [KoreanNativeToken(form: text, tag: "NNG", range: range)],
                sentences: [range],
                candidates: []
            )
        }
        func close() { factory.recordClose() }
    }
}

private actor YieldTestPersistence: KnowledgeSidecarPersisting {
    private let passStarted: XCTestExpectation?
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var loadCount = 0

    init(passStarted: XCTestExpectation?) {
        self.passStarted = passStarted
    }

    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar {
        loadCount += 1
        if let passStarted, !paused {
            paused = true
            passStarted.fulfill()
            await withCheckedContinuation { continuation = $0 }
        }
        return KnowledgeSidecar(scope: scope)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func save(_ sidecar: KnowledgeSidecar, pruningTo liveHashes: Set<String>?, scope: StoryMemoryScope) async throws {}
    func replaceWithFresh(scope: StoryMemoryScope, generation: Int) async throws -> KnowledgeSidecar {
        KnowledgeSidecar(scope: scope)
    }
    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {}
}
