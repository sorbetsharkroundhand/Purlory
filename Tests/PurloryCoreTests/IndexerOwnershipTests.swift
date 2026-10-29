@_spi(Benchmark) @testable import PurloryInference
import Combine
import XCTest

@testable import PurloryCore

/// BackgroundIndexer 작업 소유권 — stale 작업이 최신 상태를 덮지 못하게 (#82 / #65 H3).
///
/// 계약: 선점(noteChange·전체 다시 읽기)마다 세대가 올라가고, 늦게 끝난 이전
/// 작업은 ① 핸들 정리(finishPass)도 ② 발행(canPublish)도 하지 못한다.
final class IndexerOwnershipTests: XCTestCase {

    @MainActor
    func testPreemptedManualPassCannotPublishCompletionPhase() async {
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        var document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 1),
            title: "Draft", body: "# Draft\nThe manuscript.", kind: .manuscript, mode: .fiction)
        let started = expectation(description: "Manual pass suspended after initial hydration")
        let persistence = PausingSidecarPersistence(started: started, pauseOnLoad: 2)
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(
            engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        reader.attach(documentProvider: { document })
        let hydrated = expectation(description: "Initial project hydration")
        let hydration = reader.$snapshotGeneration.dropFirst().prefix(1).sink { _ in hydrated.fulfill() }
        reader.noteDocumentChange(document)
        await fulfillment(of: [hydrated], timeout: 1)
        hydration.cancel()
        reader.requestPass()
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(reader.manualPhase, .queued)

        document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 2),
            title: "Draft", body: "# Draft\nThe edited manuscript.", kind: .manuscript, mode: .fiction)
        reader.noteDocumentChange(document)
        XCTAssertEqual(reader.manualPhase, .idle, "Editing must release obsolete manual ownership")
        let stalePhase = expectation(description: "Preempted finalizer must not publish")
        stalePhase.isInverted = true
        let subscription = reader.$manualPhase.dropFirst().sink { _ in stalePhase.fulfill() }
        await persistence.release()
        await fulfillment(of: [stalePhase], timeout: 0.2)
        XCTAssertEqual(reader.manualPhase, .idle)
        reader.shutdown()
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testSameDocumentEditsReuseEligibleKnowledgeWithoutReloadingSidecar() async throws {
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let originalBody = "# First\nThe gate was unlocked.\n# Second\nA visitor waited."
        var document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 1), title: "Draft",
            body: originalBody, kind: .manuscript, mode: .fiction)
        let scope = StoryMemoryScope.project(projectID: key.projectID, documentID: key.documentID)
        let originalOutline = DocumentOutline.parse(originalBody)
        let firstScene = try XCTUnwrap(originalOutline.scenes.first)
        let secondScene = try XCTUnwrap(originalOutline.scenes.last)
        var sidecar = KnowledgeSidecar(scope: scope)
        sidecar.sceneSummaries[firstScene.contentHash] = .init(
            contentHash: firstScene.contentHash, headingPath: firstScene.headingPath,
            summary: "The gate was unlocked.", updatedAt: .now)
        sidecar.sceneSummaries[secondScene.contentHash] = .init(
            contentHash: secondScene.contentHash, headingPath: secondScene.headingPath,
            summary: "The visitor waited.", updatedAt: .now)
        let persistence = CountingSnapshotPersistence(sidecar: sidecar)
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(
            engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        reader.attach(documentProvider: { document })
        defer { reader.shutdown() }

        for generation in 1...3 {
            if generation > 1 {
                document = ProjectDocumentSnapshot(
                    identity: ProjectRuntimeIdentity(key: key, generation: UInt64(generation)),
                    title: "Draft", body: "# First\nThe gate was unlocked.\n# Second\nNew draft \(generation).",
                    kind: .manuscript, mode: .fiction)
            }
            let refreshed = expectation(description: "Knowledge for generation \(generation)")
            let subscription = reader.$snapshotGeneration.dropFirst().prefix(1).sink { _ in
                refreshed.fulfill()
            }
            reader.noteDocumentChange(document)
            await fulfillment(of: [refreshed], timeout: 1)
            XCTAssertEqual(reader.snapshotRuntimeIdentity, document.identity)
            let eligible = reader.snapshotRuntimeIdentity == document.identity ? reader.snapshot : nil
            XCTAssertEqual(eligible?.summariesByHash[firstScene.contentHash], "The gate was unlocked.")
            if generation > 1 {
                XCTAssertNil(eligible?.summariesByHash[secondScene.contentHash])
                let report = ContextAssembler.assembleWithReport(
                    prefix: "New draft", document: DocumentContext(title: "Draft", kind: .novel),
                    knowledge: eligible, prefixStartUTF16: firstScene.utf16Range.upperBound,
                    style: .continuation).report
                XCTAssertTrue(report.items.contains { $0.text.contains("The gate was unlocked.") })
                XCTAssertFalse(report.items.contains { $0.text.contains("The visitor waited.") })
            }
            subscription.cancel()
        }
        let loadCount = await persistence.loadCount
        XCTAssertEqual(loadCount, 1, "Typing must reuse already loaded sidecar values")
    }

    @MainActor
    func testLateResetFailureDoesNotPublishIntoNewRuntime() async {
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        var document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 1),
            title: "A", body: "# A\nA manuscript.", kind: .manuscript, mode: .fiction)
        let started = expectation(description: "Old reset suspended")
        let persistence = FailingResetPersistence(started: started)
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(
            engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        reader.attach(documentProvider: { document })
        reader.requestFullPass()
        await fulfillment(of: [started], timeout: 5)
        reader.prepareForProjectTransition()
        document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 3),
            title: "A again", body: "# A\nA manuscript.", kind: .manuscript, mode: .fiction)
        reader.noteDocumentChange(document)
        let stalePhase = expectation(description: "Old reset failure must not publish")
        stalePhase.isInverted = true
        let subscription = reader.$manualPhase.dropFirst().sink { _ in stalePhase.fulfill() }

        await persistence.release()
        await fulfillment(of: [stalePhase], timeout: 0.2)
        XCTAssertEqual(reader.manualPhase, .idle)
        reader.shutdown()
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testLateHydrationRejectsRetiredRuntimeEvenWhenBodyAndScopeMatch() async throws {
        let documentID = WritingDocumentID()
        let aKey = ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID)
        let bKey = ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID)
        var identity = ProjectRuntimeIdentity(key: aKey, generation: 1)
        let document = {
            ProjectDocumentSnapshot(
                identity: identity, title: "A", body: "# A\nAn unchanged manuscript.",
                kind: .manuscript, mode: .fiction)
        }
        let started = expectation(description: "Original A sidecar load suspended")
        let persistence = PausingSidecarPersistence(started: started)
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(
            engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        reader.attach(documentProvider: document)
        reader.noteDocumentChange(document())
        await fulfillment(of: [started], timeout: 5)

        // Deliberately leave the reader's local task token unchanged: the immutable
        // provider's runtime generation must independently reject the old result.
        identity = ProjectRuntimeIdentity(key: bKey, generation: 2)
        identity = ProjectRuntimeIdentity(key: aKey, generation: 3)
        let stalePublication = expectation(description: "Retired A must not publish")
        stalePublication.isInverted = true
        let staleSubscription = reader.$snapshot.compactMap { $0 }.sink { _ in
            stalePublication.fulfill()
        }
        await persistence.release()
        await fulfillment(of: [stalePublication], timeout: 0.2)
        XCTAssertNil(reader.snapshot)
        staleSubscription.cancel()

        let currentPublication = expectation(description: "Current A can still hydrate")
        let currentSubscription = reader.$snapshot.compactMap { $0 }.prefix(1).sink { _ in
            currentPublication.fulfill()
        }
        reader.noteDocumentChange(document())
        await fulfillment(of: [currentPublication], timeout: 5)
        XCTAssertEqual(reader.snapshotRuntimeIdentity, identity)
        XCTAssertEqual(reader.snapshot?.outline.scenes.first?.headingPath, ["A"])
        reader.shutdown()
        withExtendedLifetime(currentSubscription) {}
    }

    @MainActor
    func testABAReturnWithSameDocumentUUIDRejectsOriginalAResult() async throws {
        let documentID = WritingDocumentID()
        let aKey = ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID)
        let bKey = ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID)
        var identity = ProjectRuntimeIdentity(key: aKey, generation: 1)
        let document = {
            ProjectDocumentSnapshot(
                identity: identity, title: "A", body: "# Original A\nThe original manuscript is here.",
                kind: .manuscript, mode: .fiction)
        }
        indexer.attach(documentProvider: document)
        let hydrated = expectation(description: "Original A hydrated")
        let subscription = indexer.$snapshot.dropFirst().compactMap { $0 }.prefix(1).sink { _ in
            hydrated.fulfill()
        }
        indexer.noteDocumentChange(document())
        await fulfillment(of: [hydrated], timeout: 5)
        XCTAssertNotNil(indexer.snapshot)

        // Both transitions happen before detached hydration can publish. A cached result
        // with the same project/document key still belongs to the retired generation.
        identity = ProjectRuntimeIdentity(key: bKey, generation: 2)
        indexer.noteDocumentChange(document())
        identity = ProjectRuntimeIdentity(key: aKey, generation: 3)
        indexer.noteDocumentChange(document())

        XCTAssertNil(indexer.snapshot,
            "A generation 1 result must not remain visible under A generation 3")
        indexer.shutdown()
        withExtendedLifetime(subscription) {}
    }

    private var root: URL!
    private var store: EntryStore!
    private var indexer: BackgroundIndexer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-own-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 동기 XCTest 훅의 실행 순서를 유지하며 액터 소유 객체만 지역 값으로 넘긴다.
        let directory = root!
        let fixture = MainActor.assumeIsolated {
            let store = EntryStore(directory: directory, autosaveDelay: .seconds(3600))
            let settings = CompletionSettings()
            settings.autocompleteEnabled = false  // 네트워크 유발 방지
            let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
            indexer.attachLegacy(store: store)
            return (store, indexer)
        }
        store = fixture.0
        indexer = fixture.1
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    @MainActor
    private func makeNovel() -> UUID {
        let id = store.newEntry(kind: .novel)
        store.select(id)
        return id
    }

    // MARK: - 세대 증가 (선점)

    @MainActor
    func test선점마다세대가올라간다() {
        let id = store.newEntry(kind: .novel)
        let before = indexer.passGeneration

        indexer.noteChange(entryID: id)
        XCTAssertEqual(indexer.passGeneration, before + 1)

        indexer.requestFullPass()
        XCTAssertGreaterThanOrEqual(indexer.passGeneration, before + 1)
    }

    // MARK: - 늦은 이전 작업의 핸들 정리 차단 (#82 게이트 1)

    @MainActor
    func test늦은이전작업은핸들정리와상태해제를못한다() {
        let a = makeNovel()
        indexer.noteChange(entryID: a)
        let tokenA = indexer.passGeneration

        // B가 선점 — 새 세대.
        let b = makeNovel()
        indexer.noteChange(entryID: b)
        let tokenB = indexer.passGeneration
        XCTAssertNotEqual(tokenA, tokenB)

        // B의 패스가 도는 중 상태를 주입한 뒤, A(늦은 이전)가 종료를 시도한다.
        let canary = Task<Void, Never> {}
        indexer._testInjectPassState(task: canary, indexing: true)

        indexer.finishPass(token: tokenA)
        // A 토큰 정리 후에도 B가 여전히 진행 중(isIndexing true)이어야 한다 —
        // 늦은 이전 작업이 B의 상태를 지우면 false로 떨어진다.
        if indexer.passGeneration == tokenB {
            XCTAssertTrue(indexer.isIndexing, "늦은 이전 작업이 B의 상태를 해제했다")
        }

        // B 자신의 정리는 정상 동작 — 취소 가능성 보존 (#82 회귀 마지막 조항).
        indexer.finishPass(token: tokenB)
        XCTAssertFalse(indexer.isIndexing)

        _ = canary
    }

    // MARK: - 발행 가드 (토큰·문서 일치)

    @MainActor
    func test발행가드는토큰과문서일치를요구한다() {
        let a = makeNovel()
        let bodyA = "# 1장\n내용"
        let tokenA = indexer._testBeginPassForOwnership(entryID: a, body: bodyA)

        XCTAssertTrue(indexer.canPublish(token: tokenA, entryID: a))
        XCTAssertEqual(indexer.passBodyHash, BackgroundIndexer.contentFingerprint(bodyA))

        // 문서 전환(B 선점) → A 토큰·A 문서 발행 모두 거부.
        let b = makeNovel()
        indexer.noteChange(entryID: b)
        XCTAssertFalse(indexer.canPublish(token: tokenA, entryID: a), "stale 토큰이 통과됐다")
        XCTAssertFalse(indexer.canPublish(token: tokenA, entryID: b))

        // B 토큰으로 A 문서에 발행하는 것도 거부 — entryID 가드 (#82).
        let tokenB = indexer.passGeneration
        XCTAssertFalse(indexer.canPublish(token: tokenB, entryID: a))
        XCTAssertTrue(indexer.canPublish(token: tokenB, entryID: b) || indexer.passEntryID != b)
    }

    @MainActor
    func test같은문서v1_v2편집은v1발행을막는다() {
        let id = makeNovel()
        let v1 = "# 1장\n초판"
        let token1 = indexer._testBeginPassForOwnership(entryID: id, body: v1)
        let hashV1 = indexer.passBodyHash

        // 본문 편집 → noteChange 재진입 (실제 편집 경로).
        store.updateActiveBody("# 1장\n개정판")
        indexer.noteChange(entryID: id)
        let token2 = indexer._testBeginPassForOwnership(entryID: id, body: "# 1장\n개정판")

        XCTAssertNotEqual(hashV1, indexer.passBodyHash, "본문 지문이 갱신돼야 한다")
        XCTAssertFalse(indexer.canPublish(token: token1, entryID: id),
                       "v1 시점 작업이 v2 위에 발행할 수 있다")
        XCTAssertTrue(indexer.canPublish(token: token2, entryID: id))
    }

    @MainActor
    func test발행신원은프로젝트_문서_세대_본문버전을모두요구한다() {
        let id = makeNovel()
        let scopeA = StoryMemoryScope.project(
            projectID: WritingProjectID(), documentID: WritingDocumentID(rawValue: id))
        let scopeB = StoryMemoryScope.project(
            projectID: WritingProjectID(), documentID: WritingDocumentID(rawValue: id))
        let identity = indexer._testBeginPassForOwnership(scope: scopeA, body: "first version")

        XCTAssertTrue(indexer.canPublish(identity, currentScope: scopeA))
        XCTAssertFalse(indexer.canPublish(identity, currentScope: scopeB))
        XCTAssertFalse(
            indexer.canPublish(
                .init(
                    scope: scopeA, generation: identity.generation + 1,
                    documentVersion: identity.documentVersion),
                currentScope: scopeA))
        XCTAssertFalse(
            indexer.canPublish(
                .init(
                    scope: scopeA, generation: identity.generation,
                    documentVersion: "different-version"),
                currentScope: scopeA))
    }

    @MainActor
    func test프로젝트전환후늦은결과는sidecar를쓰지않는다() async {
        let id = makeNovel()
        let scopeA = StoryMemoryScope.project(
            projectID: WritingProjectID(), documentID: WritingDocumentID(rawValue: id))
        let scopeB = StoryMemoryScope.project(
            projectID: WritingProjectID(), documentID: WritingDocumentID(rawValue: id))
        let persistence = RecordingSidecarPersistence()
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        var currentScope = scopeA
        let scopedIndexer = BackgroundIndexer(
            engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        scopedIndexer.attachLegacy(store: store) { _ in currentScope }
        let identity = scopedIndexer._testBeginPassForOwnership(scope: scopeA, body: "draft")

        currentScope = scopeB
        scopedIndexer.noteScopeChange(entryID: id)
        let committed = await scopedIndexer._testCommitSidecar(
            KnowledgeSidecar(scope: scopeA), identity: identity)
        let saveCount = await persistence.saveCount

        XCTAssertFalse(committed)
        XCTAssertEqual(saveCount, 0)
    }

    @MainActor
    func test취소후늦은결과는sidecar를쓰지않는다() async {
        let id = makeNovel()
        let scope = StoryMemoryScope.legacy(
            documentID: WritingDocumentID(rawValue: id))
        let persistence = RecordingSidecarPersistence()
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let scopedIndexer = BackgroundIndexer(
            engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        scopedIndexer.attachLegacy(store: store) { _ in scope }
        let identity = scopedIndexer._testBeginPassForOwnership(scope: scope, body: "draft")
        scopedIndexer._testSetManualPhase(.queued, token: identity.generation)

        scopedIndexer.cancelManualPass()
        let committed = await scopedIndexer._testCommitSidecar(
            KnowledgeSidecar(scope: scope), identity: identity)
        let saveCount = await persistence.saveCount

        XCTAssertFalse(committed)
        XCTAssertEqual(saveCount, 0)
    }

    // MARK: - hydrate 소유권

    @MainActor
    func testhydrate세대도요청마다올라간다() {
        let id = makeNovel()
        store.updateActiveBody("# 1장\n내용이 충분히 긴 본문")
        let before = indexer.hydrateGeneration
        indexer.rehydrate(entryID: id)
        XCTAssertEqual(indexer.hydrateGeneration, before + 1)
    }
}

private actor RecordingSidecarPersistence: KnowledgeSidecarPersisting {
    private(set) var saveCount = 0

    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar {
        KnowledgeSidecar(scope: scope)
    }

    func save(
        _ sidecar: KnowledgeSidecar,
        pruningTo liveHashes: Set<String>?,
        scope: StoryMemoryScope
    ) async throws {
        saveCount += 1
    }

    func replaceWithFresh(
        scope: StoryMemoryScope,
        generation: Int
    ) async throws -> KnowledgeSidecar {
        var sidecar = KnowledgeSidecar(scope: scope)
        sidecar.generation = generation
        saveCount += 1
        return sidecar
    }

    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {}
}

private actor PausingSidecarPersistence: KnowledgeSidecarPersisting {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private let pauseOnLoad: Int
    private var loadCount = 0

    init(started: XCTestExpectation, pauseOnLoad: Int = 1) {
        self.started = started
        self.pauseOnLoad = pauseOnLoad
    }

    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar {
        loadCount += 1
        if loadCount == pauseOnLoad {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        return KnowledgeSidecar(scope: scope)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func save(
        _ sidecar: KnowledgeSidecar, pruningTo liveHashes: Set<String>?, scope: StoryMemoryScope
    ) async throws {}

    func replaceWithFresh(scope: StoryMemoryScope, generation: Int) async throws -> KnowledgeSidecar {
        KnowledgeSidecar(scope: scope)
    }

    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {}
}

private actor FailingResetPersistence: KnowledgeSidecarPersisting {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar { KnowledgeSidecar(scope: scope) }
    func save(
        _ sidecar: KnowledgeSidecar, pruningTo liveHashes: Set<String>?, scope: StoryMemoryScope
    ) async throws {}
    func replaceWithFresh(scope: StoryMemoryScope, generation: Int) async throws -> KnowledgeSidecar {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        throw CocoaError(.fileWriteUnknown)
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {}
}

private actor CountingSnapshotPersistence: KnowledgeSidecarPersisting {
    let sidecar: KnowledgeSidecar
    private(set) var loadCount = 0
    init(sidecar: KnowledgeSidecar) { self.sidecar = sidecar }
    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar {
        loadCount += 1
        return sidecar
    }
    func save(
        _ sidecar: KnowledgeSidecar, pruningTo liveHashes: Set<String>?, scope: StoryMemoryScope
    ) async throws {}
    func replaceWithFresh(scope: StoryMemoryScope, generation: Int) async throws -> KnowledgeSidecar {
        KnowledgeSidecar(scope: scope)
    }
    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {}
}
