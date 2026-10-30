import AppKit
import Foundation

/// Prepares derived story memory outside prediction. Work is scoped, cancellable,
/// incremental and subordinate to foreground editing, power and memory pressure.
@MainActor
public final class BackgroundIndexer: ObservableObject {

    /// 최신 지식 스냅샷 — `CompletionController.knowledgeProvider`가 pull한다.
    @Published public private(set) var snapshot: KnowledgeSnapshot?
    /// 진행 중 패스 표시 (툴바 칩 등 UI 관찰용 — 조용한 UI 원칙상 필수는 아니다).
    @Published public private(set) var isIndexing = false
    /// 동일 값 재발행 방지 — noteChange(키 입력당)의 무의미한 objectWillChange 차단 (#51).
    private func setIsIndexing(_ newValue: Bool) {
        if isIndexing != newValue { isIndexing = newValue }
    }
    /// 사용자 요청 패스("지금 읽기")의 단계 (#35) — 큐·진행(결정적 진행률)·취소·
    /// 차단(열/저전력)·완료/무변경을 UI가 구분해 보여준다. 자동 패스(유휴 트리거)
    /// 는 조용한 UI 원칙상 여기에 기록하지 않는다.
    public enum PassPhase: Equatable, Sendable {
        case idle
        /// 접수됨 — 백그라운드 파싱·준비 중.
        case queued
        /// 씬 단위 결정적 진행 — 처리한 더티 항목 / 전체 더티 항목.
        case reading(done: Int, total: Int)
        /// 열·저전력 게이트로 보류 — reason은 사람이 을 수 있는 문장.
        case blocked(reason: String)
        /// 패스가 돌았지만 아무것도 새로 읽지 못했다 — 모델 오류 가능성.
        case stalled(message: String)
        /// 정상 완료 — 새로 이해한 것이 있었다.
        case completedNew
        /// 이미 최신 — 더티 씬이 없어 새로 읽은 게 없었다.
        case completedNoChange
        /// 사용자가 취소했다.
        case cancelled

        /// 일시 표시 후 자동으로 idle로 돌아가는 단계인가.
        var isTransient: Bool {
            switch self {
            case .completedNew, .completedNoChange, .cancelled: true
            default: false
            }
        }
    }

    @Published public private(set) var manualPhase: PassPhase = .idle
    /// 사용자 요청 패스의 소유권 토큰 — finish/cancel 가드 (#82와 같은 규약).
    private var manualPassToken: Int?
    /// 시작 시점 스냅샷 세대 — "새로 읽은 것이 있나" 판정 기준.
    private var snapshotGenerationAtManualStart = 0
    private var manualProcessedAny = false
    private var manualDirtyTotal = 0
    private var transientClearTask: Task<Void, Never>?

    /// 스냅샷 세대 — 실제 발행마다 증가하는 싸구려 신분증 (#48). 지식 뷰들이
    /// 캐시 키로 쓴다: 스냅샷 전체 동등 비교(사건 수천 개 배열)를 매 패스
    /// 반복하는 대신 정수 비교로 "바뀌었나"를 판정한다.
    @Published public private(set) var snapshotGeneration = 0
    /// 인물 감지 후보 (M6, PLAN §7) — 감지는 자동, **등록은 사용자 확인**
    /// (CLAUDE.md §3). 바이블 팝오버가 전부 나열해 검토받는다 (M6-8).
    @Published public private(set) var characterCandidates: [CharacterDetector.Candidate] = []
    /// 후보가 어느 문서 것인지 — 문서 전환 시 낡은 후보를 보여주지 않기 위한 짝.
    @Published public private(set) var candidatesEntryID: UUID?
    /// 일관성 경고 (M7) — 스냅샷과 같은 주기로 갱신. **비침습**: 사이드바
    /// 배지·목록만, 본문엔 아무것도 긋지 않는다 (ConsistencyChecker 참조).
    @Published public private(set) var warnings: [ConsistencyWarning] = []
    @Published public private(set) var continuityCandidates: [ContinuityCandidate] = []

    /// 동일 값 발행 가드 — 같은 경고 배열을 다시 대입해도 objectWillChange가
    /// 울리지 않는다 (#48: 관찰 fan-out의 3번째 축, @Published 쓰기 최소화).
    private func setWarnings(_ newValue: [ConsistencyWarning]) {
        if warnings != newValue { warnings = newValue }
    }
    private func setContinuityCandidates(_ newValue: [ContinuityCandidate]) {
        if continuityCandidates != newValue { continuityCandidates = newValue }
    }

    /// 사이드카·스냅샷 성능 측정 (요구사항 §33) — 로컬 전용, SQLite 이관 시점
    /// 판단의 근거 데이터. 원격 전송 절대 금지 (CLAUDE.md §1-3).
    public struct KnowledgeMetrics: Equatable, Sendable {
        /// 직렬화된 사이드카 크기 (bytes).
        public var sidecarBytes: Int = 0
        public var sceneCount: Int = 0
        /// 씬당 평균 Narrative Intelligence 크기 (bytes).
        public var bytesPerScene: Int = 0
        /// 사이드카 로드 지연 (ms).
        public var loadMs: Double = 0
        /// 사이드카 저장 지연 (ms).
        public var saveMs: Double = 0
        /// 스냅샷(그래프 파생 포함) 조립 지연 (ms).
        public var deriveMs: Double = 0
    }

    @Published public private(set) var metrics: KnowledgeMetrics?

    /// 빠른 패스 유휴 대기 — 예측 디바운스(수백 ms)와 별도 타이머 (PLAN §9).
    nonisolated static let fastPassIdle: Duration = .seconds(5)
    /// 깊은 패스 유휴 대기.
    nonisolated static let deepPassIdle: Duration = .seconds(60)
    /// 빠른 패스의 유휴당 LLM 호출 상한 (PLAN §9 예산).
    nonisolated static let fastPassCallBudget = 2
    /// 요약에 넣는 씬 원문 상한 — 프리필은 취소 불가 구간이라, 이 길이가
    /// "타이핑 재개 → 예측이 엔진을 기다리는" 최악 지연을 결정한다 (짧게 유지).
    /// 씬 분할(docs/m6-scene-split.md)이 같은 값을 상한으로 쪼개므로, 이제
    /// `.prefix`는 안전망일 뿐 실제로 자르지 않는다 — 이해 범위 100%.
    nonisolated public static let maxSceneCharacters = DocumentOutline.maxSegmentUTF16

    /// 커서 위치 제공자 (ContentView가 배선) — 씬 분할 후 씬이 수십 개가
    /// 되므로, 깊은 패스는 **커서에서 가까운 씬부터** 이해한다. 6장을 쓰는
    /// 동안 1장부터 읽으면 정작 필요한 지식이 마지막에 온다
    /// (docs/m6-scene-split.md §5 — 분할 설계의 일부).
    public var caretProvider: (() -> Int?)?

    private var memoryPressurePaused = false
    private var profileTasks: [UUID: Task<Void, Never>] = [:]
    private var profileGeneration = 0
    private static let memoryPressureReason = "메모리가 부족해 읽기를 쉬고 있어요 — 여유가 생기면 다시 시도해 주세요"

    /// Recovery only admits a later edit or explicit request; it never reloads a model.
    public func setMemoryPressurePaused(_ paused: Bool) {
        guard memoryPressurePaused != paused else { return }
        memoryPressurePaused = paused
        if paused {
            setContinuityCandidates([])
            let hadManualWork = manualPassToken != nil
            shutdown()
            manualPassToken = nil
            transientClearTask?.cancel()
            manualPhase = hadManualWork ? .blocked(reason: Self.memoryPressureReason) : .idle
        } else if case .blocked(let reason) = manualPhase, reason == Self.memoryPressureReason {
            manualPhase = .idle
        }
    }

    private func cancelProfiles() {
        profileGeneration += 1
        for task in profileTasks.values { task.cancel() }
        profileTasks.removeAll()
    }

    private let engine: CompletionEngine
    private let settings: CompletionSettings
    private let sidecarPersistence: any KnowledgeSidecarPersisting
    private weak var legacyStore: EntryStore?
    private var legacyScopeProvider: ((UUID) -> StoryMemoryScope?)?
    private var documentProvider: (() -> ProjectDocumentSnapshot?)?
    private var writerReader = WriterDocumentReader()
    private var observedRuntimeIdentity: ProjectRuntimeIdentity?
    public private(set) var snapshotRuntimeIdentity: ProjectRuntimeIdentity?
    /// One active project's already-loaded derived values. Edits revalidate them against
    /// the new body in background without adding sidecar reads to the typing path.
    private var preparedProjectSidecar: KnowledgeSidecar?
    let originalNamePreparation = OriginalNameAnchorPreparation()
    public var originalNameAnchorsEnabled = false {
        didSet {
            guard originalNameAnchorsEnabled != oldValue else { return }
            prepareOriginalNameAnchors()
        }
    }
    public var originalNameAnchors: OriginalNameAnchorIndex? {
        guard let document = currentDocument(),
            originalNamePreparation.scope == document.scope,
            originalNamePreparation.runtimeIdentity == document.runtimeIdentity else { return nil }
        return originalNamePreparation.index
    }
    public func setForegroundCompletionBusy(_ busy: Bool) {
        originalNamePreparation.setForegroundBusy(busy)
    }
    private func prepareOriginalNameAnchors() {
        guard !memoryPressurePaused, originalNameAnchorsEnabled, let document = currentDocument(), document.isFiction else {
            originalNamePreparation.shutdown()
            return
        }
        originalNamePreparation.prepare(body: document.body, documentID: document.id,
            scope: document.scope, runtimeIdentity: document.runtimeIdentity, characters: document.characters)
    }

    /// Knowledge-specific metadata stays in the reader adapter, outside ProjectSession.
    private struct DocumentInput {
        let id: UUID
        let scope: StoryMemoryScope
        let runtimeIdentity: ProjectRuntimeIdentity?
        let body: String
        let isFiction: Bool
        let characters: [CharacterCard]
        let overrides: [NarrativeOverride]
        let recorded: [RecordedConversation]
        let rejectedNames: [String]
    }

    private func currentDocument() -> DocumentInput? {
        if let documentProvider {
            guard let document = documentProvider(),
                let writer = try? writerReader.read(document) else { return nil }
            let key = document.identity.key
            return DocumentInput(
                id: key.documentID.rawValue,
                scope: .project(projectID: key.projectID, documentID: key.documentID),
                runtimeIdentity: document.identity, body: document.body,
                isFiction: document.mode == .fiction,
                characters: writer.characters, overrides: writer.narrativeOverrides,
                recorded: writer.recordedConversations, rejectedNames: writer.rejectedCharacterNames)
        }
        guard let entry = legacyStore?.activeEntry,
            let scope = legacyScopeProvider?(entry.id)
        else { return nil }
        return DocumentInput(
            id: entry.id, scope: scope, runtimeIdentity: nil, body: entry.body,
            isFiction: entry.resolvedKind == .novel,
            characters: entry.characters ?? [], overrides: entry.narrativeOverrides ?? [],
            recorded: entry.recordedConversations ?? [],
            rejectedNames: entry.rejectedCharacterNames ?? [])
    }

    private var fastTimer: Task<Void, Never>?
    private var deepTimer: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    /// 패스 소유권 토큰 — 선점(새 noteChange·requestPass·전체 다시 읽기)마다
    /// 올라간다. 늦게 끝난 이전 작업은 자기 토큰이 현재와 같을 때만 상태를
    /// 건드린다 (이슈 #82).
    public private(set) var passGeneration = 0
    /// 현재 패스가 읽고 있는 문서·본문 지문 — 발행 가드의 entryID/hash 절반.
    public private(set) var passEntryID: UUID?
    public private(set) var passBodyHash: String?
    public private(set) var passScope: StoryMemoryScope?

    struct PassIdentity: Equatable, Sendable {
        let scope: StoryMemoryScope
        let generation: Int
        let documentVersion: String
        var runtimeIdentity: ProjectRuntimeIdentity? = nil
    }

    /// 본문 지문 — 실행마다 달라지는 HashValue 대신 안정 해시 (이슈 #82).
    nonisolated static func contentFingerprint(_ body: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in body.utf8 {
            h = (h ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// 테스트 전용 상태 주입 — 소유권 가드를 엔진 실행 없이 검증하기 위한 것 (#82).
    func _testInjectPassState(task: Task<Void, Never>?, indexing: Bool) {
        passTask = task
        isIndexing = indexing
    }

    /// 테스트 전용 — startPass의 소유권 장부(세대·문서·지문)만 재현해 토큰을 돌려준다.
    func _testBeginPassForOwnership(entryID: UUID, body: String) -> Int {
        let scope = StoryMemoryScope.legacy(
            documentID: WritingDocumentID(rawValue: entryID))
        return _testBeginPassForOwnership(scope: scope, body: body).generation
    }

    func _testBeginPassForOwnership(
        scope: StoryMemoryScope,
        body: String
    ) -> PassIdentity {
        passGeneration += 1
        passScope = scope
        passEntryID = scope.documentID.rawValue
        passBodyHash = Self.contentFingerprint(body)
        return PassIdentity(
            scope: scope, generation: passGeneration,
            documentVersion: Self.contentFingerprint(body),
            runtimeIdentity: documentProvider?()?.identity)
    }

    /// 테스트 전용 — 사용자 패스 단계를 소유권과 함께 심는다 (#35).
    func _testSetManualPhase(_ phase: PassPhase, token: Int) {
        manualPassToken = token
        manualPhase = phase
    }

    /// 이 토큰의 패스가 아직 현재 소유자인가 — 작업 종료 시 핸들 정리 가드.
    func finishPass(token: Int) {
        guard passGeneration == token else { return }  // 늦은 이전 작업 — 무시
        passTask = nil
        setIsIndexing(false)
        if manualPassToken == token {
            manualPassToken = nil  // 소유권 해제 — 다음 요청을 받는다 (#35).
        }
    }

    /// 발행 가드 — 토큰·대상 문서 일치만 통과 (스냅샷·후보·지표 공용, #82).
    func canPublish(token: Int, entryID: UUID) -> Bool {
        passGeneration == token && passEntryID == entryID
    }

    func canPublish(
        _ identity: PassIdentity,
        currentScope: StoryMemoryScope? = nil
    ) -> Bool {
        let resolvedScope = currentScope ?? currentDocument()?.scope
        return passGeneration == identity.generation
            && passScope == identity.scope
            && passBodyHash == identity.documentVersion
            && resolvedScope == identity.scope
            && identity.runtimeIdentity == documentProvider?()?.identity
    }

    private func owns(_ identity: PassIdentity) -> Bool {
        guard canPublish(identity),
            let entry = currentDocument(), entry.id == identity.scope.documentID.rawValue
        else { return false }
        return Self.contentFingerprint(entry.body) == identity.documentVersion
    }

    /// 테스트 전용 — 패스 출력 적용 경로(동일 값 가드 포함)를 엔진 없이 재현한다 (#48).
    func _testApplyPassOutputs(
        snapshot: KnowledgeSnapshot?, warnings: [ConsistencyWarning],
        metrics: KnowledgeMetrics?
    ) {
        if let snapshot {
            self.snapshot = snapshot
            snapshotGeneration += 1
        }
        setWarnings(warnings)
        if let metrics, self.metrics != metrics { self.metrics = metrics }
    }

    /// 앱 수명 동안의 인덱서 — 종료 훅(AppDelegate)이 접근하려고 둔다.
    /// EntryStore.current와 같은 패턴 (이슈 #65 Gate 0 teardown 수정).
    public private(set) weak static var current: BackgroundIndexer?

    public init(
        engine: CompletionEngine,
        settings: CompletionSettings = .shared,
        sidecarPersistence: (any KnowledgeSidecarPersisting)? = nil
    ) {
        self.engine = engine
        self.settings = settings
        self.sidecarPersistence = sidecarPersistence ?? KnowledgeSidecarRepository()
        Self.current = self
        // 앱 비활성 = 장기 유휴와 같은 신호 — 곧바로 깊은 패스 (PLAN §9).
        // 앱 수명 싱글턴이라 옵저버를 해제하지 않는다 (weak self라 누수 없음).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.startPass(deep: true) }
        }
    }

    /// ContentView가 1회 배선 — 패스 시점에 활성 문서를 pull하기 위한 약참조.
    public func attach(documentProvider: @escaping () -> ProjectDocumentSnapshot?) {
        prepareForProjectTransition()
        legacyStore = nil
        legacyScopeProvider = nil
        self.documentProvider = documentProvider
    }

    public func attachLegacy(
        store: EntryStore,
        scopeProvider: ((UUID) -> StoryMemoryScope?)? = nil
    ) {
        prepareForProjectTransition()
        documentProvider = nil
        self.legacyStore = store
        self.legacyScopeProvider = scopeProvider ?? { entryID in
            .legacy(documentID: WritingDocumentID(rawValue: entryID))
        }
    }

    /// 앱 종료 직전 호출 — 유휴 타이머와 진행 패스를 접어, 엔진의 드레인이
    /// 길어지지 않게 한다 (이슈 #65 Gate 0 teardown 세그폴트 수정). 종료 시점의
    /// 백그라운드 이해는 어차피 버려질 결과다 — 원문은 flush로 이미 안전하다.
    public func shutdown() {
        cancelProfiles()
        originalNamePreparation.shutdown()
        passGeneration += 1
        hydrateGeneration += 1
        fastTimer?.cancel()
        fastTimer = nil
        deepTimer?.cancel()
        deepTimer = nil
        hydrateTask?.cancel()
        hydrateTask = nil
        passTask?.cancel()
        passTask = nil
        resetTask?.cancel()
        resetTask = nil
        setIsIndexing(false)
    }

    // MARK: - 트리거

    public func noteDocumentChange(_ document: ProjectDocumentSnapshot) {
        guard documentProvider?()?.identity == document.identity else { return }
        if observedRuntimeIdentity?.key != document.identity.key {
            prepareForProjectTransition()
        }
        observedRuntimeIdentity = document.identity
        noteChange(entryID: document.identity.key.documentID.rawValue)
    }

    /// 본문 편집·문서 전환 알림 (EntryStore 훅) — 진행 중 패스를 선점하고
    /// 유휴 타이머를 다시 감는다.
    public func noteChange(entryID: UUID) {
        setContinuityCandidates([])
        // Original-backed actions retire synchronously, including while analysis is paused.
        setWarnings([])
        guard !memoryPressurePaused else { return }
        prepareOriginalNameAnchors()
        // 선점: 백그라운드 생성은 예측(그리고 그 앞의 타이핑)에 항상 진다 (CLAUDE.md §2-6).
        // 세대를 먼저 올린다 — 취소가 늦게 끝난 이전 작업의 모든 발행/정리를 무효화 (#82).
        passGeneration += 1
        if manualPassToken != nil {
            manualPassToken = nil
            transientClearTask?.cancel()
            manualPhase = .idle
        }
        passEntryID = nil
        passBodyHash = nil
        passScope = nil
        passTask?.cancel()
        passTask = nil
        resetTask?.cancel()
        resetTask = nil
        setIsIndexing(false)

        // 저장된 지식의 웜 로드 — 앱 시작·문서 전환 직후 사이드카를 읽어 즉시
        // 발행한다 (LLM 없음). 이게 없으면 껐다 켠 뒤 패스가 돌 때까지(자동완성
        // 꺼짐이면 영영) 타임라인·카드가 비어 "지식이 사라진" 것처럼 보인다 —
        // 디스크엔 있는데 UI가 못 본 것. 스냅샷 entryID 비교라 타이핑 중엔 O(1).
        hydrateIfNeeded(entryID: entryID)

        fastTimer?.cancel()
        deepTimer?.cancel()
        // 자동완성이 꺼져 있으면 타이머조차 감지 않는다 — 어차피 패스가 거부되고,
        // 키 입력 경로에 태스크 생성 비용을 남길 이유가 없다 (랙 진단의 대조군:
        // 스위치를 끄면 백그라운드 이해 관련 작업이 문자 그대로 0이어야 한다).
        // (웜 로드는 위에서 이미 했다 — 읽기 전용이라 스위치와 무관.)
        guard settings.autocompleteEnabled else { return }
        fastTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.fastPassIdle)
            guard !Task.isCancelled else { return }
            self?.startPass(deep: false)
        }
        deepTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.deepPassIdle)
            guard !Task.isCancelled else { return }
            self?.startPass(deep: true)
        }
    }

    /// Project/document selection changes invalidate ownership even when the editor text
    /// did not emit a change notification.
    public func noteScopeChange(entryID: UUID) {
        prepareForProjectTransition()
        prepareOriginalNameAnchors()
        hydrateIfNeeded(entryID: entryID)
    }

    /// Cancels old ownership without reading the session before its next publication.
    public func prepareForProjectTransition() {
        setContinuityCandidates([])
        cancelProfiles()
        originalNamePreparation.shutdown()
        passGeneration += 1
        passEntryID = nil
        passBodyHash = nil
        passScope = nil
        hydrateGeneration += 1
        passTask?.cancel()
        passTask = nil
        resetTask?.cancel()
        resetTask = nil
        hydrateTask?.cancel()
        hydrateTask = nil
        fastTimer?.cancel()
        deepTimer?.cancel()
        setIsIndexing(false)
        snapshot = nil
        snapshotRuntimeIdentity = nil
        preparedProjectSidecar = nil
        observedRuntimeIdentity = nil
        characterCandidates = []
        candidatesEntryID = nil
        manualPassToken = nil
        manualPhase = .idle
        setWarnings([])
    }

    @discardableResult
    func _testCommitSidecar(
        _ sidecar: KnowledgeSidecar,
        identity: PassIdentity
    ) async -> Bool {
        guard canPublish(identity) else { return false }
        do {
            try await sidecarPersistence.save(sidecar, pruningTo: nil, scope: identity.scope)
        } catch {
            return false
        }
        return canPublish(identity)
    }

    // MARK: - 웜 로드 (저장된 지식 → 스냅샷, LLM 없음)

    private var hydrateTask: Task<Void, Never>?
    /// hydrate 소유권 토큰 — 새 요청마다 올라가 늦은 발행을 무효화 (#82).
    public private(set) var hydrateGeneration = 0

    /// 활성 문서의 스냅샷이 없으면 사이드카에서 만든다 — 결정적·읽기 전용이라
    /// 게이트(열·저전력·자동완성) 대상이 아니다. 사이드카가 비어 있어도
    /// 발행한다: 씬 분할·"아직 안 읽음" 상태가 즉시 보이는 것 자체가 가치다.
    /// `force`: 사용자 수정(오버라이드) 변경 시 — 이미 스냅샷이 있어도 다시
    /// 조립해 수정이 즉시 보이게 한다 (LLM 없음, 결정적 재조립).
    private func hydrateIfNeeded(entryID: UUID, force: Bool = false) {
        guard !memoryPressurePaused else { return }
        guard let entry = currentDocument(), entry.id == entryID else { return }
        let scope = entry.scope
        let runtimeIdentity = entry.runtimeIdentity
        guard force || snapshot?.storyMemory?.scope != scope
            || snapshotRuntimeIdentity != runtimeIdentity
        else { return }
        guard entry.isFiction else { return }
        let body = entry.body
        let characters = entry.characters
        let overrides = entry.overrides
        let recorded = entry.recorded
        let prepared = !force && runtimeIdentity != nil && preparedProjectSidecar?.scope == scope
            ? preparedProjectSidecar : nil

        hydrateGeneration += 1
        let token = hydrateGeneration
        hydrateTask?.cancel()
        // 파싱·디스크 읽기를 메인에서 떼어낸다 (30만 자 파싱이 메인을 막지 않게).
        let persistence = sidecarPersistence
        hydrateTask = Task.detached(priority: .utility) { [weak self] in
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let outline = DocumentOutline.parse(body)
            guard !outline.scenes.isEmpty, !Task.isCancelled else { return }
            let loadStart = CFAbsoluteTimeGetCurrent()
            let sidecar: KnowledgeSidecar
            if let prepared {
                sidecar = prepared
            } else {
                sidecar = await persistence.load(scope: scope)
            }
            guard !Task.isCancelled, sidecar.scope == scope else { return }
            let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            let utterances = DialogueAttribution.utterances(in: body, cards: characters)
            let deriveStart = CFAbsoluteTimeGetCurrent()
            let snapshot = Self.makeSnapshot(
                entryID: entryID, scope: scope, outline: outline, sidecar: sidecar,
                utterances: utterances, overrides: overrides, body: body,
                characters: characters, recordedConversations: recorded)
            let deriveMs = (CFAbsoluteTimeGetCurrent() - deriveStart) * 1000
            let metrics = Self.measure(
                sidecar: sidecar, sceneCount: outline.scenes.count,
                loadMs: loadMs, deriveMs: deriveMs)
            let warnings = ConsistencyChecker.check(
                snapshot: snapshot, characters: characters, source: body)
            let candidates = ContinuityCandidate.prepare(snapshot: snapshot, warnings: warnings, scope: scope, source: body)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 늦은 이전 hydrate는 현재 문서에만, 자기 토큰이 유효할 때만 (#82).
                guard self.hydrateGeneration == token else { return }
                guard let current = self.currentDocument(), current.id == entryID,
                    current.scope == scope, current.runtimeIdentity == runtimeIdentity,
                    current.body == body
                else { return }
                // 그 사이 진짜 패스가 이 문서 걸 발행했다면 그쪽이 더 최신이다.
                guard force || self.snapshot?.storyMemory?.scope != scope
                    || self.snapshotRuntimeIdentity != runtimeIdentity
                else { return }
                if runtimeIdentity != nil { self.preparedProjectSidecar = sidecar }
                self.setContinuityCandidates([])
                self.snapshotRuntimeIdentity = runtimeIdentity
                self.snapshot = snapshot
                self.setWarnings(warnings)
                self.setContinuityCandidates(candidates)
                self.snapshotGeneration += 1
                if self.metrics != metrics { self.metrics = metrics }
            }
        }
    }

    /// 사이드카 크기·지연 측정 (요구사항 §33) — 발행 주기마다 갱신되는 개발 지표.
    nonisolated static func measure(
        sidecar: KnowledgeSidecar, sceneCount: Int,
        loadMs: Double, deriveMs: Double, saveMs: Double = 0
    ) -> KnowledgeMetrics {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = (try? encoder.encode(sidecar))?.count ?? 0
        return KnowledgeMetrics(
            sidecarBytes: bytes,
            sceneCount: sceneCount,
            bytesPerScene: sceneCount > 0 ? bytes / sceneCount : 0,
            loadMs: loadMs, saveMs: saveMs, deriveMs: deriveMs)
    }

    /// 사용자 수정 반영 재조립 — EntryStore.narrativeOverridesDidChange가 부른다.
    /// LLM 없이 사이드카 + 새 오버라이드로 스냅샷만 다시 만든다.
    public func rehydrate(entryID: UUID) {
        hydrateIfNeeded(entryID: entryID, force: true)
    }

    // MARK: - 패스 실행

    /// 사용자 명시 요청 — 바이블·타임라인 패널의 "지금 읽기" 버튼 (M6-8).
    ///
    /// 자동완성 스위치와 **무관하게** 깊은 패스를 1회 돈다: 버튼을 눌렀다는
    /// 것 자체가 "지금 이해를 만들어 달라"는 동의라, 자동 게이트(모델 로드
    /// 방지)를 우회한다. 열·저전력 게이트는 그대로 존중한다 (CLAUDE.md §4).
    ///
    /// **증분이다** — 해시 메모에 없는(바뀐·새) 씬만 읽는다. 전부 최신이면
    /// 즉시 끝난다. 이미 분석된 문서를 강제로 다시 읽으려면 `requestFullPass`.
    public func requestPass() {
        guard !memoryPressurePaused else {
            manualPhase = .blocked(reason: Self.memoryPressureReason)
            return
        }
        // 자동 패스가 이미 돌고 있으면 그걸로 충분하다 — 중복 금지.
        guard passTask == nil, resetTask == nil else { return }
        beginManualPhase()
        startPass(deep: true, userInitiated: true)
        if passTask != nil {
            manualPassToken = passGeneration  // startPass가 방금 올린 토큰 (#35)
        } else {
            manualPhase = .idle
        }
    }

    /// 사용자 요청 패스 취소 (#35) — 진행 중 생성을 접고 상태를 정리한다.
    /// 아직 발행하지 않은 candidate는 버리고 공식 snapshot은 그대로 둔다.
    public func cancelManualPass() {
        guard manualPassToken != nil else { return }
        manualPassToken = nil
        passGeneration += 1
        passTask?.cancel()
        passTask = nil
        resetTask?.cancel()
        resetTask = nil
        setIsIndexing(false)
        setTransientPhase(.cancelled)
    }

    /// 수동 패스 시작 기록 — 세대 스냅샷을 잡아 완료 판정("새로 읽은 것이 있는가")
    /// 의 기준으로 삼는다. 토큰은 startPass가 확정한 뒤 호출부가 따낸다 (#35).
    private func beginManualPhase() {
        transientClearTask?.cancel()
        snapshotGenerationAtManualStart = snapshotGeneration
        manualProcessedAny = false
        manualDirtyTotal = 0
        manualPhase = .queued
    }

    /// 수동 패스 종료 판정 (#35) — 새 이해(세대 증가)·무변경·조용한 중단을 갈라
    /// 표시한다. 취소는 cancelManualPass가 직접 표시하고, 게이트 차단은 진행 중
    /// onBlocked가 이미 표시했으므로 여기서 덮지 않는다.
    private func finishManualPhase(identity: PassIdentity) {
        guard manualPassToken == identity.generation, owns(identity) else { return }
        switch manualPhase {
        case .blocked, .cancelled:
            return  // 이미 의미 있는 상태 — 유지.
        default:
            break
        }
        let producedNew = snapshotGeneration > snapshotGenerationAtManualStart
        if producedNew {
            setTransientPhase(.completedNew)
        } else if manualProcessedAny || manualDirtyTotal == 0 {
            // 처리는 했으나 발행이 없었거나(오버라이드만 재조립) 애초 더티가 없었다.
            setTransientPhase(.completedNoChange)
        } else {
            // 더티가 있었는데 하나도 처리하지 못했다 — 모델 오류 가능성 (#35).
            setTransientPhase(.stalled(message: "씬을 읽지 못했어요 — 모델 상태를 확인하거나 다시 시도해 주세요"))
        }
    }

    /// 일시 단계 표시 후 자동 복귀 — completed/cancelled 계열 (#35).
    private func setTransientPhase(_ phase: PassPhase) {
        manualPhase = phase
        transientClearTask?.cancel()
        guard phase.isTransient else { return }
        transientClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if self?.manualPhase == phase { self?.manualPhase = .idle }
        }
    }

    /// 전체 다시 읽기 — 파생 캐시(사이드카)를 버리고 처음부터 깊은 패스를 돈다.
    ///
    /// "이미 분석된 내용이 있으면 다시 읽을 방법이 없다"는 문제의 해법:
    /// 증분(requestPass)은 메모 적중 씬을 건너뛰므로, 분석 품질이 불만이거나
    /// 프롬프트가 개선된 뒤에는 이 통로로 강제 재분석한다. **사용자 수정은
    /// 안전하다** — 오버라이드는 entries.json에 살고, 여기서 지우는 것은
    /// 파생 캐시뿐이다 (CLAUDE.md §5-5: 실패해도 원문이 안전).
    public func requestFullPass() {
        guard !memoryPressurePaused else {
            manualPhase = .blocked(reason: Self.memoryPressureReason)
            return
        }
        guard let entry = currentDocument(), entry.isFiction else { return }
        let scope = entry.scope
        let runtimeIdentity = entry.runtimeIdentity
        beginManualPhase()
        // 진행 중 패스 선점 — 낡은 사이드카에 체크포인트를 덧쓰지 않게 먼저 멈춘다.
        passGeneration += 1
        passTask?.cancel()
        passTask = nil
        resetTask?.cancel()
        resetTask = nil
        setIsIndexing(false)
        let resetToken = passGeneration
        manualPassToken = resetToken
        let entryID = entry.id
        let documentVersion = Self.contentFingerprint(entry.body)
        resetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let previous = await self.sidecarPersistence.load(scope: scope)
            guard !Task.isCancelled else { return }
            guard self.passGeneration == resetToken,
                let current = self.currentDocument(), current.scope == scope,
                current.id == entryID, current.runtimeIdentity == runtimeIdentity,
                Self.contentFingerprint(current.body) == documentVersion
            else { return }
            do {
                let fresh = try await self.sidecarPersistence.replaceWithFresh(
                    scope: scope, generation: previous.generation + 1)
                if self.passGeneration == resetToken,
                    self.currentDocument()?.runtimeIdentity == runtimeIdentity,
                    runtimeIdentity != nil
                {
                    self.preparedProjectSidecar = fresh
                }
            } catch {
                guard !Task.isCancelled, self.passGeneration == resetToken,
                    let current = self.currentDocument(), current.scope == scope,
                    current.runtimeIdentity == runtimeIdentity,
                    Self.contentFingerprint(current.body) == documentVersion
                else { return }
                self.resetTask = nil
                self.setTransientPhase(.stalled(message: "파생 지식을 초기화하지 못했어요"))
                return
            }
            guard !Task.isCancelled else { return }
            guard self.passGeneration == resetToken,
                let current = self.currentDocument(), current.scope == scope,
                current.id == entryID, current.runtimeIdentity == runtimeIdentity,
                Self.contentFingerprint(current.body) == documentVersion
            else { return }
            self.resetTask = nil
            self.startPass(deep: true, userInitiated: true)
            self.manualPassToken = self.passGeneration
        }
    }

    private func startPass(deep: Bool, userInitiated: Bool = false) {
        guard !memoryPressurePaused else { return }
        guard passTask == nil else { return }  // 이미 도는 중 — 중복 금지
        // 자동완성이 꺼져 있으면 지식도 만들지 않는다 — 백그라운드 이해가
        // 대용량 모델 다운로드를 유발해서는 안 된다 (폴더 명명과 같은 규칙).
        // 단 사용자 명시 요청(requestPass)은 예외 — 누른 것이 곧 동의다.
        guard settings.autocompleteEnabled || userInitiated else { return }
        guard let entry = currentDocument(), entry.isFiction else { return }
        let scope = entry.scope
        let body = entry.body
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let entryID = entry.id
        var parameters = settings.parameters
        // 요약은 낮은 온도로 결정성 우선 — 같은 씬이 패스마다 다른 요약을 얻으면
        // B 블록이 흔들려 KV 프리픽스가 식는다 (PLAN §12).
        parameters.temperature = min(parameters.temperature, 0.3)
        let liveEntryIDs = Set(legacyStore?.entries.map(\.id) ?? [])
        // 사건의 참여자로 링크할 수 있는 인물 = 등록된 카드뿐 (CLAUDE.md §3).
        let characters = entry.characters
        // 인물 감지 제외 목록 — 이미 등록된 이름·별칭 + 사용자가 무시한 이름.
        let knownNames = Set(
            entry.characters.flatMap { card in
                [card.name] + card.aliases.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }.filter { !$0.isEmpty })
        let rejectedNames = Set(entry.rejectedNames)
        let overrides = entry.overrides
        let recorded = entry.recorded
        let allowsLegacyMetadataWrites = legacyStore != nil && documentProvider == nil
        let caret = caretProvider?()

        setIsIndexing(true)
        passGeneration += 1
        let token = passGeneration
        let bodyHash = Self.contentFingerprint(body)
        passEntryID = entryID
        passBodyHash = bodyHash
        passScope = scope
        let identity = PassIdentity(
            scope: scope, generation: token, documentVersion: bodyHash,
            runtimeIdentity: entry.runtimeIdentity)
        let persistence = sidecarPersistence
        // 파싱·디스크 IO·프롬프트 준비를 메인에서 떼어낸다 — 생성 자체는 엔진
        // actor에서 돌므로, 여기서 중요한 건 30만 자 파싱이 메인을 막지 않는 것.
        // self는 앱 수명 객체라 패스 동안의 강참조가 수명을 늘리지 않는다.
        passTask = Task.detached(priority: .utility) { [engine, self] in
            let owned = { @MainActor () -> Bool in
                self.owns(identity) && !Task.isCancelled
            }
            // 인물 감지 — 결정적·LLM 없음이라 게이트·예산 밖에서 먼저 (PLAN §7).
            let outline = DocumentOutline.parse(body)
            let candidates = CharacterDetector.detect(
                body: body, outline: outline,
                known: knownNames, rejected: rejectedNames)
            var superseded = false
            await MainActor.run {
                // 늦은 이전 작업은 후보 발표·자동 등록조차 하지 않는다 (#82).
                guard owned() else { superseded = true; return }
                // HIGH 신뢰(구조 신호 다수) 후보는 자동 등록한다 (요구사항 §16,
                // CLAUDE.md §3 갱신) — 카드에 자동 등록 표식이 남고 삭제는 한 번의
                // 클릭이다. 별칭 후보(기존 인물의 변형일 가능성)는 자동 등록하지
                // 않는다 — 병합/신규는 사용자 결정 (요구사항 §17).
                let auto = candidates.filter {
                    allowsLegacyMetadataWrites && $0.confidence == .high && $0.aliasOfKnown == nil
                }
                for candidate in auto { self.autoRegister(candidate, in: entryID) }
                let remaining = candidates.filter { candidate in
                    !auto.contains(where: { $0.name == candidate.name })
                }
                if self.characterCandidates != remaining {
                    self.characterCandidates = remaining
                }
                if self.candidatesEntryID != entryID { self.candidatesEntryID = entryID }
            }
            if superseded {
                await MainActor.run { self.finishPass(token: token) }
                return
            }
            // 자동 등록이 카드를 늘렸을 수 있다 — 패스는 최신 카드로 돈다.
            let liveCharacters = await MainActor.run {
                allowsLegacyMetadataWrites ? (self.currentDocument()?.characters ?? characters) : characters
            }
            await Self.runPass(
                deep: deep, scope: scope, entryID: entryID, body: body,
                parameters: parameters, engine: engine,
                persistence: persistence,
                liveEntryIDs: liveEntryIDs, characters: liveCharacters,
                overrides: overrides, recordedConversations: recorded,
                caretUTF16: caret
            ) { snapshot in
                // 일관성 검사는 스냅샷과 같은 주기 — 백그라운드에서 계산하고
                // 결과만 메인으로 (렌더 경로 재계산 금지, docs/editor-perf.md 4차).
                let warnings = ConsistencyChecker.check(
                    snapshot: snapshot, characters: characters, source: body)
                let candidates = ContinuityCandidate.prepare(snapshot: snapshot, warnings: warnings, scope: identity.scope, source: body)
                Task { @MainActor in
                    // 이 새 Task는 부모 취소를 물려받지 않는다 — 소유권 가드가 대신
                    // 걸러낸다 (토큰·문서 일치, #82).
                    guard self.owns(identity) else { return }
                    self.setContinuityCandidates([])
                    self.snapshotRuntimeIdentity = identity.runtimeIdentity
                    self.snapshot = snapshot
                    self.setWarnings(warnings)
                    self.setContinuityCandidates(candidates)
                    self.snapshotGeneration += 1
                }
            } publishMetrics: { metrics in
                Task { @MainActor in
                    guard self.owns(identity) else { return }
                    if self.metrics != metrics { self.metrics = metrics }
                }
            } progress: { done, total in
                // "지금 읽기"의 결정적 진행률 (#35) — 자동 패스엔 노출 안 함.
                Task { @MainActor in
                    guard self.manualPassToken == token, self.owns(identity) else { return }
                    if done > 0 { self.manualProcessedAny = true }
                    self.manualDirtyTotal = total
                    self.manualPhase = .reading(done: done, total: total)
                }
            } onBlocked: { reason in
                Task { @MainActor in
                    guard self.manualPassToken == token, self.owns(identity) else { return }
                    self.manualPhase = .blocked(reason: reason)
                }
            } commit: { candidate, liveHashes in
                guard await MainActor.run(body: { owned() }) else { return false }
                do {
                    try await persistence.save(
                        candidate, pruningTo: liveHashes, scope: scope)
                } catch {
                    return false
                }
                return await MainActor.run {
                    guard owned() else { return false }
                    if identity.runtimeIdentity != nil { self.preparedProjectSidecar = candidate }
                    return true
                }
            }
            await MainActor.run {
                self.finishManualPhase(identity: identity)
                self.finishPass(token: token)
            }
        }
    }

    // MARK: - 인물 후보 확인 (등록은 사용자, CLAUDE.md §3)

    /// HIGH 신뢰 후보의 자동 등록 (요구사항 §16) — 사용자 확인 없이 카드를
    /// 만들되 `autoRegistered` 표식을 남긴다. 사용자가 카드를 편집하면 표식이
    /// 사라지고, 삭제는 언제나 한 번의 클릭이다 (기억은 사용자의 것, §1-5).
    /// 등록 대상은 **감지된 문서**다 — activeEntry가 아니라. 감지와 MainActor 홉
    /// 사이에 문서를 전환하면 다른 원고에 카드가 새어드는 레이스가 생긴다.
    private func autoRegister(
        _ candidate: CharacterDetector.Candidate, in entryID: UUID
    ) {
        guard documentProvider == nil, let store = legacyStore,
            let entry = store.entries.first(where: { $0.id == entryID })
        else { return }
        // 이미 같은 이름의 카드가 있으면 만들지 않는다 (known 필터의 안전망).
        guard (entry.characters ?? []).allSatisfy({ $0.name != candidate.name }) else { return }
        let card = CharacterCard(
            name: candidate.name,
            aliases: candidate.aliasForms.joined(separator: ", "),
            autoRegistered: true)
        store.upsertCharacter(card, in: entry.id)
        profileInBackground(card: card, name: candidate.name, entry: entry)
    }

    /// 후보 등록 — 카드를 즉시 만들고, 소개는 백그라운드 LLM 프로파일링이
    /// 채운다 (PLAN §7 깔때기 3단). 프로파일링 실패 시 이름만 남는다 —
    /// 이름만으로도 카드 선택(§11)에는 충분하다.
    public func approveCandidate(_ candidate: CharacterDetector.Candidate) {
        guard documentProvider == nil, let store = legacyStore, let entry = store.activeEntry else { return }
        let card = CharacterCard(
            name: candidate.name,
            aliases: candidate.aliasForms.joined(separator: ", "))
        store.upsertCharacter(card, in: entry.id)
        characterCandidates.removeAll { $0.name == candidate.name }

        profileInBackground(card: card, name: candidate.name, entry: entry)
    }

    /// 별칭으로 등록 (요구사항 §17) — "재형"이 기존 "김재형"의 별칭이라는
    /// 사용자 판정. 새 카드를 만들지 않고 기존 카드의 별칭 목록에 붙인다.
    public func approveCandidateAsAlias(
        _ candidate: CharacterDetector.Candidate, of ownerName: String
    ) {
        guard documentProvider == nil, let store = legacyStore, let entry = store.activeEntry,
            var owner = entry.characters?.first(where: { $0.name == ownerName })
        else { return }
        var aliases = owner.aliases.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for form in [candidate.name] + candidate.aliasForms where !aliases.contains(form) {
            aliases.append(form)
        }
        owner.aliases = aliases.joined(separator: ", ")
        store.upsertCharacter(owner, in: entry.id)
        characterCandidates.removeAll { $0.name == candidate.name }
    }

    /// 카드 프로파일링 공용 경로 — 등록(수동·자동·별칭) 직후 소개를 채운다.
    private func profileInBackground(card: CharacterCard, name: String, entry: JournalEntry) {
        guard !memoryPressurePaused else { return }
        let body = entry.body
        let parameters = settings.parameters
        let entryID = entry.id
        let token = UUID(), generation = profileGeneration
        profileTasks[token] = Task { [engine, weak store = legacyStore, weak self] in
            defer { self?.profileTasks[token] = nil }
            guard !Task.isCancelled else { return }
            let note = await Self.profileCharacter(
                named: name, in: body,
                engine: engine, parameters: parameters)
            guard !Task.isCancelled, let note, let store, let self,
                !self.memoryPressurePaused, self.profileGeneration == generation,
                self.documentProvider == nil, self.legacyStore === store
            else { return }
            // 그 사이 사용자가 직접 소개를 썼거나 카드를 잠갔다면 그쪽이 이긴다
            // (CLAUDE.md §1-5 — locked는 자동 추출이 덮지 못한다, PLAN §6.2).
            guard
                var current = store.entries.first(where: { $0.id == entryID })?
                    .characters?.first(where: { $0.id == card.id }),
                current.note.isEmpty, current.locked != true
            else { return }
            current.note = note
            store.upsertCharacter(current, in: entryID)
        }
    }

    /// 후보 무시 — 거부 목록에 저장, 같은 이름은 다시 묻지 않는다 (PLAN §7).
    public func rejectCandidate(_ candidate: CharacterDetector.Candidate) {
        guard documentProvider == nil, let store = legacyStore, let id = store.activeEntry?.id else { return }
        store.rejectCharacterName(candidate.name, in: id)
        characterCandidates.removeAll { $0.name == candidate.name }
    }

    public func approveCandidate(
        _ candidate: CharacterDetector.Candidate,
        in session: ProjectSession,
        identity: ProjectRuntimeIdentity
    ) {
        guard let snapshot = session.selectedDocumentSnapshot, snapshot.identity == identity else { return }
        let card = CharacterCard(
            name: candidate.name,
            aliases: candidate.aliasForms.joined(separator: ", "))
        guard (try? ProjectWriterEditing.perform(.character(card), in: session, identity: identity)) != nil else { return }
        characterCandidates.removeAll { $0.name == candidate.name }
        profileInBackground(card: card, name: candidate.name, body: snapshot.body, session: session, identity: identity)
    }

    public func approveCandidateAsAlias(
        _ candidate: CharacterDetector.Candidate,
        of ownerName: String,
        in session: ProjectSession,
        identity: ProjectRuntimeIdentity
    ) {
        guard let snapshot = session.selectedDocumentSnapshot, snapshot.identity == identity else { return }
        let docID = identity.key.documentID
        guard let writer = try? WriterDocumentData.decode(snapshot.userData[WriterDocumentData.key(for: docID)], documentID: docID),
              var owner = writer.characters.first(where: { $0.name == ownerName }) else { return }
        var aliases = owner.aliases.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for form in [candidate.name] + candidate.aliasForms where !aliases.contains(form) {
            aliases.append(form)
        }
        owner.aliases = aliases.joined(separator: ", ")
        guard (try? ProjectWriterEditing.perform(.character(owner), in: session, identity: identity)) != nil else { return }
        characterCandidates.removeAll { $0.name == candidate.name }
    }

    public func rejectCandidate(
        _ candidate: CharacterDetector.Candidate,
        in session: ProjectSession,
        identity: ProjectRuntimeIdentity
    ) {
        guard (try? ProjectWriterEditing.perform(.rejectName(candidate.name), in: session, identity: identity)) != nil else { return }
        characterCandidates.removeAll { $0.name == candidate.name }
    }

    private func profileInBackground(
        card: CharacterCard,
        name: String,
        body: String,
        session: ProjectSession,
        identity: ProjectRuntimeIdentity
    ) {
        guard !memoryPressurePaused else { return }
        let parameters = settings.parameters
        let token = UUID(), generation = profileGeneration
        profileTasks[token] = Task { [engine, weak session, weak self] in
            defer { self?.profileTasks[token] = nil }
            guard !Task.isCancelled else { return }
            let note = await Self.profileCharacter(
                named: name, in: body,
                engine: engine, parameters: parameters)
            guard !Task.isCancelled, let note, let session, let self,
                  !self.memoryPressurePaused, self.profileGeneration == generation,
                  let currentSnapshot = session.selectedDocumentSnapshot,
                  currentSnapshot.identity == identity else { return }
            let docID = identity.key.documentID
            guard let writer = try? WriterDocumentData.decode(currentSnapshot.userData[WriterDocumentData.key(for: docID)], documentID: docID),
                  var current = writer.characters.first(where: { $0.id == card.id }),
                  current.note.isEmpty, current.locked != true else { return }
            current.note = note
            try? ProjectWriterEditing.perform(.character(current), in: session, identity: identity)
        }
    }

    /// 등록 직후의 인물 프로파일링 — 이름이 등장하는 문장들만 모아 한 번의
    /// instruct로 성격·말투 초안을 뽑는다 (PLAN §7, `generateFolderName` 규율).
    nonisolated private static func profileCharacter(
        named name: String, in body: String,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> String? {
        // 언급 문장 수집 (결정적) — 앞에서부터 최대 8문장·1000자.
        var snippets: [String] = []
        var total = 0
        for line in body.split(separator: "\n") where line.contains(name) {
            let sentence = line.trimmingCharacters(in: .whitespaces)
            snippets.append(sentence)
            total += sentence.count
            if snippets.count >= 8 || total > 1_000 { break }
        }
        guard !snippets.isEmpty else { return nil }
        let note =
            (try? await engine.generateOneShot(
                system: """
                    너는 소설 인물 카드를 쓰는 도우미다. 발췌에 근거해 인물의 \
                    성격·말투·관계를 한국어 1~2문장(최대 140자)으로 쓴다. \
                    발췌에 없는 내용은 지어내지 않는다. 설명·머리말 없이 본문만 출력한다.
                    """,
                user: """
                    인물 '\(name)'에 대한 발췌다. 이 인물의 카드 소개를 써라.

                    \(snippets.joined(separator: "\n"))
                    """,
                maxTokens: 96,
                parameters: parameters)) ?? ""
        let collapsed = note
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : String(collapsed.prefix(140))
    }

    /// 한 번의 이해 패스 — 값 입력만 받아 detached에서 돈다.
    nonisolated private static func runPass(
        deep: Bool,
        scope: StoryMemoryScope,
        entryID: UUID,
        body: String,
        parameters: CompletionParameters,
        engine: CompletionEngine,
        persistence: any KnowledgeSidecarPersisting,
        liveEntryIDs: Set<UUID>,
        characters: [CharacterCard],
        overrides: [NarrativeOverride],
        recordedConversations: [RecordedConversation] = [],
        caretUTF16: Int?,
        publish: @Sendable @escaping (KnowledgeSnapshot) -> Void,
        publishMetrics: @Sendable @escaping (KnowledgeMetrics) -> Void = { _ in },
        /// 씬 단위 결정적 진행 (처리한 수, 전체 더티 수) — "지금 읽기" 표시용 (#35).
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        /// 게이트(열·저전력)로 보류될 때 사유 보고 (#35).
        onBlocked: (@Sendable (String) -> Void)? = nil,
        /// The only sidecar publication boundary. It revalidates pass ownership before
        /// and after the write, so cancelled or switched work cannot keep publishing.
        commit: @Sendable @escaping (KnowledgeSidecar, Set<String>?) async -> Bool
    ) async {
        guard gateAllows(deep: deep) else { return }

        let outline = DocumentOutline.parse(body)
        guard !outline.scenes.isEmpty else { return }
        // 커서 거리순 순회 — 씬 분할로 씬이 수십 개가 되면, 쓰고 있는 자리
        // 근처의 이해가 먼저 준비돼야 한다. 스냅샷·저장은 해시 키라 처리
        // 순서와 무관하고, 선점당해도 "가까운 것부터 남는" 성질이 생긴다.
        let orderedScenes: [DocumentOutline.Scene]
        if let caretUTF16 {
            orderedScenes = outline.scenes.sorted {
                distance(from: $0, to: caretUTF16) < distance(from: $1, to: caretUTF16)
            }
        } else {
            orderedScenes = outline.scenes
        }
        var sidecar = await persistence.load(scope: scope)
        guard sidecar.scope == scope else { return }
        let text = body as NSString

        // 결정적 진행률의 분모 — 더티 항목 수 (요약·사건·앎·구간 중 하나라도 없는 씬).
        let dirtyTotal = orderedScenes.filter { scene in
            sidecar.sceneSummaries[scene.contentHash] == nil
                || (!deep ? false :
                    sidecar.events[scene.contentHash] == nil
                    || sidecar.insights[scene.contentHash] == nil
                    || sidecar.segments[scene.contentHash] == nil)
        }.count
        var dirtyDone = 0
        func reportProgress() {
            guard let progress else { return }
            progress(dirtyDone, max(dirtyTotal, 1))
        }
        reportProgress()
        // 게이트 차단은 조용히 return하지 않고 이유를 남긴다 (#35).
        func gateOrReport(_ deepFlag: Bool) -> Bool {
            if gateAllows(deep: deepFlag) { return true }
            if let reason = gateBlockReason(
                deep: deepFlag,
                thermalState: ProcessInfo.processInfo.thermalState,
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled),
                let onBlocked
            {
                onBlocked(reason)
            }
            return false
        }
        // 대화 귀속 (PLAN §7·§6.4) — 결정적·LLM 없음이라 패스마다 재계산.
        // 사이드카에 저장하지 않는 파생 — 스냅샷에만 실린다.
        let utterances = DialogueAttribution.utterances(in: body, cards: characters)

        // ① 더티 씬 요약 — 해시 메모에 없는 씬만, 커서에서 가까운 순.
        var callBudget = deep ? Int.max : fastPassCallBudget
        for scene in orderedScenes {
            guard callBudget > 0 else { break }
            guard sidecar.sceneSummaries[scene.contentHash] == nil else { continue }
            guard !Task.isCancelled else { return }
            guard gateOrReport(deep) else { return }

            let sceneText = String(
                text.substring(
                    with: NSRange(
                        location: scene.utf16Range.lowerBound,
                        length: scene.utf16Range.count)
                ).prefix(maxSceneCharacters))
            guard sceneText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40
            else { continue }  // 요약할 내용이 없는 토막은 건너뛴다

            let analysis = await analyzeScene(
                sceneText, engine: engine, parameters: parameters)
            callBudget -= 1
            guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
            guard let analysis else { continue }  // 실패는 다음 패스가 재시도

            sidecar.sceneSummaries[scene.contentHash] = .init(
                contentHash: scene.contentHash,
                headingPath: scene.headingPath,
                summary: analysis.summary,
                title: analysis.title,
                narrativeType: analysis.narrativeType,
                pov: analysis.pov,
                location: analysis.location,
                updatedAt: .now)
            dirtyDone += 1
            reportProgress()
        }

        // ② 사건 추출 (깊은 패스 전용, PLAN §6.3) — 요약이 끝난 씬만.
        // 요약보다 뒤에 두는 이유: 빠른 패스의 LLM 예산은 요약이 먼저 쓴다
        // (docs/m6-events.md 결정 3).
        if deep, !Task.isCancelled {
            relinkParticipants(sidecar: &sidecar, characters: characters)
            for scene in orderedScenes {
                guard !Task.isCancelled else { return }
                guard gateOrReport(true) else { return }
                // 키 존재 = 추출 완료(빈 배열이면 "사건 없음") — 메모 적중은 건너뛴다.
                guard sidecar.events[scene.contentHash] == nil else { continue }
                let sceneText = String(
                    text.substring(
                        with: NSRange(
                            location: scene.utf16Range.lowerBound,
                            length: scene.utf16Range.count)
                    ).prefix(maxSceneCharacters))
                let extracted = await extractEvents(
                    sceneText, sceneHash: scene.contentHash,
                    characters: characters, engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                guard let extracted else { continue }  // 실패·인물 미등록 — 재시도 여지
                sidecar.events[scene.contentHash] = extracted
                dirtyDone += 1
                reportProgress()
            }
        }

        // ②b 심화 추출 (깊은 패스 전용, v4 — 앎·관계). 사건과 별도
        // 메모 키(insights) — 한쪽 실패가 다른 쪽을 지우지 않는다 (실패 격리).
        if deep, !Task.isCancelled {
            for scene in orderedScenes {
                guard !Task.isCancelled else { return }
                guard gateOrReport(true) else { return }
                guard sidecar.insights[scene.contentHash] == nil else { continue }
                let sceneText = String(
                    text.substring(
                        with: NSRange(
                            location: scene.utf16Range.lowerBound,
                            length: scene.utf16Range.count)
                    ).prefix(maxSceneCharacters))
                let insights = await extractInsights(
                    sceneText, sceneHash: scene.contentHash,
                    characters: characters, engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                guard let insights else { continue }  // 실패 — 다음 패스가 재시도
                sidecar.insights[scene.contentHash] = insights
                dirtyDone += 1
                reportProgress()
            }
        }

        // ②c 서사 구간 분석 (깊은 패스 전용, v5 — 요구사항 §7–§10).
        // 다단계: 결정적 후보 감지가 게이트다 — 시간 이동 표지가 전혀 없고 씬
        // 유형도 현재면 LLM 없이 "단일 현재 서사"로 메모한다 (토큰 절약).
        if deep, !Task.isCancelled {
            for scene in orderedScenes {
                guard !Task.isCancelled else { return }
                guard gateOrReport(true) else { return }
                guard sidecar.segments[scene.contentHash] == nil else { continue }
                let sceneText = String(
                    text.substring(
                        with: NSRange(
                            location: scene.utf16Range.lowerBound,
                            length: scene.utf16Range.count)
                    ).prefix(maxSceneCharacters))
                let storedType = sidecar.sceneSummaries[scene.contentHash]?.narrativeType
                    .map { SceneNarrativeType.normalize($0) }
                let hasShiftHint =
                    (storedType ?? .present) != .present
                    || TemporalShiftDetector.hasCandidate(in: sceneText)
                guard hasShiftHint else {
                    sidecar.segments[scene.contentHash] = SceneSegmentation()  // 메모: 단일 서사
                    continue
                }
                let segments = await analyzeSegments(
                    sceneText, sceneHash: scene.contentHash,
                    engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                guard let segments else { continue }  // 실패 — 다음 패스가 재시도
                sidecar.segments[scene.contentHash] = SceneSegmentation(segments: segments)
            }
        }

        // ③ 상향 전파 (깊은 패스 전용) — 장 → 작품, 더티 경로만 (PLAN §6.1).
        if deep, !Task.isCancelled {
            await propagate(
                outline: outline, sidecar: &sidecar,
                parameters: parameters, engine: engine)
            guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
            // 어떤 저널도 참조하지 않는 사이드카 정리 (삭제된 작품의 파생물).
            if case .legacy = scope {
                await persistence.pruneLegacyOrphans(
                    keeping: Set(liveEntryIDs.map(WritingDocumentID.init(rawValue:))))
            }
        }

        // ④ 사건 그래프 분석 (깊은 패스 전용, v5 — 요구사항 §3·§6·§12·§29).
        // 살아있는 씬의 사건 전체를 담화 순서로 모아 한 번의 호출로 인과·동일
        // 사건·시간 관계 후보를 뽑는다. 메모 키 = 사건 키 집합의 결합 해시.
        if deep, !Task.isCancelled, gateAllows(deep: true) {
            var orderedEvents: [StoryEvent] = []
            for scene in outline.scenes {
                orderedEvents.append(contentsOf: sidecar.events[scene.contentHash] ?? [])
            }
            let analysisEvents = uniqueEventsForAnalysis(orderedEvents)
            _ = clearAnalysesBelowThreshold(
                sidecar: &sidecar, uniqueEventCount: analysisEvents.count)
            let memoHash = combinedHash(analysisEvents.map(\.stableKey))
            if analysisEvents.count >= 2, sidecar.eventGraph?.memoHash != memoHash {
                let analysis = await analyzeEventGraph(
                    events: analysisEvents, characters: characters,
                    engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                if let analysis = analysis {
                    sidecar.eventGraph = EventGraphAnalysis(
                        causalLinks: analysis.causalLinks,
                        identities: analysis.identities,
                        chronoEdges: analysis.chronoEdges,
                        memoHash: memoHash)
                }
            }
        }

        // ⑤b 플롯 스레드 추론 (깊은 패스 전용, v6). 사건 목록 + 인과 힌트를
        // 한 번의 호출로 플롯 라인으로 묶는다. 메모 키 = 사건 키 집합 해시.
        // 재분석 결과는 이전 스레드에 멤버 겹침으로 이어(reconcile) stableID가
        // 유지된다 — 오버라이드·색·레인의 앵커가 흔들리지 않는다 (요구사항 §10).
        if deep, !Task.isCancelled, gateAllows(deep: true) {
            var orderedEvents: [StoryEvent] = []
            for scene in outline.scenes {
                orderedEvents.append(contentsOf: sidecar.events[scene.contentHash] ?? [])
            }
            let analysisEvents = uniqueEventsForAnalysis(orderedEvents)
            let memoHash = combinedHash(analysisEvents.map(\.stableKey) + ["plot"])
            if analysisEvents.count >= 3, sidecar.plotThreads?.memoHash != memoHash {
                let threads = await analyzePlotThreads(
                    events: analysisEvents, characters: characters,
                    causalLinks: sidecar.eventGraph?.causalLinks ?? [],
                    engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                if let threads = threads {
                    sidecar.plotThreads = PlotThreadAnalysis(
                        threads: PlotThreadParser.reconcile(
                            new: threads,
                            previous: sidecar.plotThreads?.threads ?? []),
                        memoHash: memoHash)
                }
            }
        }

        // ⑥ 기록된 대화 보완 (깊은 패스 전용, v5 — 요구사항 §19). 기록 시점에
        // 비어 있던 주제·어조를 채운다. 메모 = 기록의 contentHash (원문이
        // 바뀌면 재분석). 사용자 기록 자체(entries.json)는 건드리지 않는다.
        if deep, !Task.isCancelled {
            for record in recordedConversations {
                guard !Task.isCancelled, gateAllows(deep: true) else { return }
                let key = record.id.uuidString
                if sidecar.conversationMeta[key]?.contentHash == record.contentHash { continue }
                let anchored = ConversationDetector.reanchor(record, in: text) ?? record
                let start = min(max(0, anchored.utf16Start), text.length)
                let end = min(max(start, anchored.utf16End), text.length)
                guard end > start else { continue }
                let conversationText = String(
                    text.substring(with: NSRange(location: start, length: end - start))
                        .prefix(maxSceneCharacters))
                let meta = await analyzeConversation(
                    conversationText, contentHash: record.contentHash,
                    engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                guard let meta else { continue }
                sidecar.conversationMeta[key] = meta
            }
            // 기록이 삭제된 보완 데이터 정리.
            let liveIDs = Set(recordedConversations.map { $0.id.uuidString })
            sidecar.conversationMeta = sidecar.conversationMeta.filter {
                liveIDs.contains($0.key)
            }
        }

        guard !Task.isCancelled else { return }
        let saveStart = CFAbsoluteTimeGetCurrent()
        guard await commit(sidecar, Set(outline.scenes.map(\.contentHash))) else { return }
        let saveMs = (CFAbsoluteTimeGetCurrent() - saveStart) * 1000
        let deriveStart = CFAbsoluteTimeGetCurrent()
        let snapshot = makeSnapshot(
            entryID: entryID, scope: scope, outline: outline, sidecar: sidecar,
            utterances: utterances, overrides: overrides, body: body,
            characters: characters,
            recordedConversations: recordedConversations)
        let deriveMs = (CFAbsoluteTimeGetCurrent() - deriveStart) * 1000
        publish(snapshot)
        // 성능 지표 (요구사항 §33) — 깊은 패스 끝에서 한 번 갱신.
        publishMetrics(
            measure(
                sidecar: sidecar, sceneCount: outline.scenes.count,
                loadMs: 0, deriveMs: deriveMs, saveMs: saveMs))
    }

    /// 장·작품 요약 상향 전파 — 하위 요약이 전부 준비된 노드만, 결합 해시가
    /// 바뀐(더티) 노드만 다시 만든다.
    nonisolated private static func propagate(
        outline: DocumentOutline,
        sidecar: inout KnowledgeSidecar,
        parameters: CompletionParameters,
        engine: CompletionEngine
    ) async {
        let changes = HierarchicalMemory.changes(previous: sidecar, outline: outline)
        let chapters = HierarchicalMemory.chapterGroups(in: outline)

        // 이번 패스에서 확보한 롤업 — 경로별 기록 후 아래에서 문서 순서로 조립한다.
        var madeByPath: [[String]: KnowledgeSidecar.ChapterSummary] = [:]
        for chapter in chapters {
            guard !Task.isCancelled, gateAllows(deep: true) else { return }
            let childSummaries = chapter.scenes.compactMap {
                sidecar.sceneSummaries[$0.contentHash]?.summary
            }
            // 하위가 다 준비되지 않았거나, 씬 하나뿐이면(씬 요약으로 충분) 건너뛴다.
            guard childSummaries.count == chapter.scenes.count,
                chapter.scenes.count >= 2
            else { continue }
            if !changes.dirtyChapters.contains(chapter.nodeID),
                let existing = sidecar.chapterSummaries.first(where: {
                    $0.headingPath == chapter.path && $0.childrenHash == chapter.childrenHash
                })
            {
                madeByPath[chapter.path] = existing  // 메모 적중 — 재요약 금지
                continue
            }
            let summary = await rollup(
                childSummaries, level: .chapter, engine: engine, parameters: parameters)
            guard let summary else { continue }
            madeByPath[chapter.path] =
                .init(
                    headingPath: chapter.path, childrenHash: chapter.childrenHash,
                    summary: summary, updatedAt: .now)
        }
        // 문서 순서 조립 — 갱신된 장은 새 값, 아니면 기존 롤업을 물려받는다.
        // 완전 교체하면 더티 윈도우(씬 재요약 중·롤업 실패)에 유효한 장 요약이
        // 통째로 사라졌다 다음 패스에 되살아난다 — 요약 피라미드의 증분 규율(§6.1) 위반.
        sidecar.chapterSummaries = chapters.compactMap { chapter in
            madeByPath[chapter.path]
                ?? sidecar.chapterSummaries.first { $0.headingPath == chapter.path }
        }

        // 작품 요약 — 장 요약(없으면 씬 요약)에서. 씬 3개 미만이면 만들지 않는다
        // (C 창이 이미 전부를 본다 — 토큰당 품질, CLAUDE.md §5-1).
        guard outline.scenes.count >= 3, !Task.isCancelled else { return }
        let sources =
            sidecar.chapterSummaries.count >= 2
            ? sidecar.chapterSummaries.map(\.summary)
            : outline.scenes.compactMap { sidecar.sceneSummaries[$0.contentHash]?.summary }
        guard sources.count >= 2 else { return }
        guard changes.workIsDirty else { return }
        let childrenHash = HierarchicalMemory.workChildrenHash(for: outline)
        let summary = await rollup(
            sources, level: .work, engine: engine, parameters: parameters)
        guard let summary else { return }
        sidecar.workSummary = .init(
            childrenHash: childrenHash, summary: summary, updatedAt: .now)
    }

    // MARK: - 씬 분석 호출 (공용 — 인덱서 본 경로 + PurloryBench 리플레이 측정)

    /// 씬 분석 결과 — 요약 + 내용 기반 제목 + 서사 메타 (v4, 요구사항 §6·§7).
    public struct SceneAnalysis: Equatable, Sendable {
        public var title: String?
        public var summary: String
        public var narrativeType: String?
        public var pov: String?
        public var location: String?
    }

    /// 씬 요약 길이 상한 — 기존 120자에서 상향. **문장 경계에서만 자른다**
    /// (SentenceClamp) — "감정조차 포즈로 여"처럼 중간에서 끊긴 요약이 저장되던
    /// 문제의 근본 수정 절반 (나머지 절반은 생성 토큰 예산 64→192 상향).
    nonisolated public static let maxSummaryCharacters = 160

    /// 씬 하나를 분석한다 (제목·요약·유형·시점·장소 — 한 번의 호출).
    /// 실패·빈 결과는 nil — 호출부가 무시한다 (PLAN §9).
    /// public인 이유: 벤치가 **완전히 같은 프롬프트·규격**으로 지식을 만들어야
    /// 측정이 본 경로를 대표한다 (CLAUDE.md §2-7).
    nonisolated public static func analyzeScene(
        _ text: String, engine: CompletionEngine, parameters: CompletionParameters
    ) async -> SceneAnalysis? {
        // 헤딩 한 줄뿐인 초미니 씬은 요약할 내용이 없다 — 모델에 넣으면 환각
        // 요약이 생긴다 (벤치에서 확인). 인덱서·벤치 공용 가드.
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return nil
        }
        let output =
            (try? await engine.generateOneShot(
                system: Prompts.sceneSystem,
                user: Prompts.sceneUser(text),
                // 다섯 줄 형식 — 빈 줄 조기 종료를 끄고 토큰 예산으로만 제한한다.
                // 64토큰이 한국어 120자를 못 채워 요약이 중간에서 잘리던 원인.
                maxTokens: 192,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        return parseSceneAnalysis(output)
    }

    /// 벤치 호환 래퍼 — 분석에서 요약만 취한다 (같은 프롬프트·같은 경로).
    nonisolated public static func summarizeScene(
        _ text: String, engine: CompletionEngine, parameters: CompletionParameters
    ) async -> String? {
        await analyzeScene(text, engine: engine, parameters: parameters)?.summary
    }

    /// 씬 분석 출력 파싱 — `키: 값` 줄 형식 (EventParser와 같은 관대한 파싱).
    /// 요약 줄이 없으면 nil — 제목만으로는 지식이 아니다.
    nonisolated static func parseSceneAnalysis(_ output: String) -> SceneAnalysis? {
        var title: String?
        var summary: String?
        var type: String?
        var pov: String?
        var location: String?
        for rawLine in output.split(separator: "\n") {
            let line = EventParser.stripListMarker(
                rawLine.trimmingCharacters(in: .whitespaces))
            guard let colon = line.firstIndex(of: ":") else {
                // 키 없는 첫 산문 줄 — 구형 응답(요약만 출력)의 폴백.
                if summary == nil, line.count >= 10 { summary = line }
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "제목": title = SentenceClamp.clamp(value, to: 24)
            case "요약": summary = SentenceClamp.clamp(value, to: maxSummaryCharacters)
            case "유형", "종류": type = value
            case "시점", "시점인물": pov = String(value.prefix(20))
            case "장소": location = String(value.prefix(30))
            default: break
            }
        }
        guard let summary, !summary.isEmpty else { return nil }
        return SceneAnalysis(
            title: title, summary: summary, narrativeType: type,
            pov: pov, location: location)
    }

    /// 심화 추출 (v4, PLAN §6.5) — 앎·관계. 깊은 패스 전용.
    /// 사건 추출과 별도 호출인 이유: 여러 필드를 한 프롬프트에 욱여넣으면 소형
    /// 모델의 형식 준수가 무너진다 (요약/사건 분리와 같은 실패 격리).
    nonisolated public static func extractInsights(
        _ text: String, sceneHash: String, characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> SceneInsights? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return SceneInsights()  // 초미니 씬 — 뽑을 것이 없다 (환각 방지)
        }
        let nameIndex = EventParser.nameIndex(characters)
        let output =
            (try? await engine.generateOneShot(
                system: Prompts.insightSystem,
                user: Prompts.insightUser(text, names: nameIndex.keys.sorted()),
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }  // 실패 — 다음 패스가 재시도
        return InsightParser.parse(
            output, sceneHash: sceneHash, nameIndex: nameIndex, sceneText: text)
    }

    /// 서사 구간 분석 (v5, 요구사항 §7–§10) — 씬 안의 시간·관점 전환 구간을
    /// 한 번의 structured 호출로 뽑는다. 파서가 인용을 원문 대조로 검증하므로
    /// 환각 경계는 구조적으로 걸러진다. 실패는 nil — 다음 패스가 재시도.
    /// public인 이유: 벤치가 같은 프롬프트·규격으로 측정해야 한다 (CLAUDE.md §2-7).
    nonisolated public static func analyzeSegments(
        _ text: String, sceneHash: String,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [NarrativeSegment]? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return []  // 초미니 씬 — 구간이 있을 수 없다 (환각 방지)
        }
        let output =
            (try? await engine.generateOneShot(
                system: Prompts.segmentSystem,
                user: Prompts.segmentUser(text),
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        // "없음"만 출력 = 씬 전체가 단일 서사 (유효한 완료).
        if output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("없음") {
            return []
        }
        return SegmentParser.parse(output, sceneHash: sceneHash, sceneText: text)
    }

    /// 사건 그래프 분석 (v5, 요구사항 §3·§6·§12·§29) — 사건 목록 전체를 번호로
    /// 제시하고 인과·동일 사건·시간 관계 후보를 한 번의 호출로 받는다.
    /// 사건은 짧은 요약(≤80자)이라 수십 개여도 프롬프트가 작다. 실패는 nil.
    nonisolated public static func analyzeEventGraph(
        events: [StoryEvent], characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> EventGraphParser.Result? {
        let capped = uniqueEventsForAnalysis(events)
        guard capped.count >= 2 else {
            return EventGraphParser.Result(causalLinks: [], identities: [], chronoEdges: [])
        }
        let names = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0.name) })
        let listing = capped.enumerated()
            .map { offset, event in
                let who = event.participants.compactMap { names[$0] }.joined(separator: "·")
                return "\(offset + 1). \(event.summary)\(who.isEmpty ? "" : " [\(who)]")"
            }
            .joined(separator: "\n")
        let output =
            (try? await engine.generateOneShot(
                system: Prompts.eventGraphSystem,
                user: "사건 목록 (본문 등장 순서):\n\(listing)",
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        return EventGraphParser.parse(output, keys: capped.map(\.stableKey))
    }

    /// 플롯 스레드 추론 (v6) — 사건 목록을 플롯 라인으로 묶는다. 인물 겹침이
    /// 아니라 목표·갈등·질문의 연속성으로 묶으라는 규칙이 프롬프트의 핵심이다
    /// (Branch ≠ Character). 인과 후보를 힌트로 함께 준다 — 인과 사슬은 같은
    /// 플롯일 강한 신호다. 실패는 nil (기존 분석 유지).
    nonisolated public static func analyzePlotThreads(
        events: [StoryEvent], characters: [CharacterCard],
        causalLinks: [CausalLink],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [PlotThread]? {
        let capped = uniqueEventsForAnalysis(events)
        guard capped.count >= 3 else { return [] }
        let names = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0.name) })
        let listing = capped.enumerated()
            .map { offset, event in
                let who = event.participants.compactMap { names[$0] }.joined(separator: "·")
                return "\(offset + 1). \(event.summary)\(who.isEmpty ? "" : " [\(who)]")"
            }
            .joined(separator: "\n")
        // 인과 힌트 — 번호로 환산 가능한 것만 (같은 40개 상한 안).
        let numberByKey = Dictionary(
            uniqueKeysWithValues: capped.enumerated().map { ($0.element.stableKey, $0.offset + 1) })
        let hints = causalLinks.compactMap { link -> String? in
            guard let from = numberByKey[link.fromKey], let to = numberByKey[link.toKey]
            else { return nil }
            return "\(from) → \(to) (\(link.kind.rawValue))"
        }
        let hintBlock = hints.isEmpty ? "" : "\n\n인과 관계 힌트:\n\(hints.joined(separator: "\n"))"
        let output =
            (try? await engine.generateOneShot(
                system: Prompts.plotThreadSystem,
                user: "사건 목록 (본문 등장 순서):\n\(listing)\(hintBlock)",
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("없음") {
            return []
        }
        return PlotThreadParser.parse(output, keys: capped.map(\.stableKey))
    }

    /// 같은 사건의 재서술은 stableKey가 겹친다. 번호 목록과 key→번호 인덱스를
    /// 1:1로 유지하도록 첫 등장만 남긴 뒤 분석 상한을 적용한다 (PLAN §6.6).
    nonisolated static func uniqueEventsForAnalysis(
        _ events: [StoryEvent], limit: Int = 40
    ) -> [StoryEvent] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        var result: [StoryEvent] = []
        result.reserveCapacity(min(limit, events.count))
        for event in events where seen.insert(event.stableKey).inserted {
            result.append(event)
            if result.count == limit { break }
        }
        return result
    }

    /// 중복 정규화 뒤 분석 최소 개수를 못 채우면 과거 결과도 더는 유효하지 않다.
    /// raw 사건 수만 보고 건너뛰면 삭제된 사건을 가리키는 그래프가 남는다 (PLAN §6.6).
    @discardableResult
    nonisolated static func clearAnalysesBelowThreshold(
        sidecar: inout KnowledgeSidecar, uniqueEventCount: Int
    ) -> Bool {
        var changed = false
        if uniqueEventCount < 2, sidecar.eventGraph != nil {
            sidecar.eventGraph = nil
            changed = true
        }
        if uniqueEventCount < 3, sidecar.plotThreads != nil {
            sidecar.plotThreads = nil
            changed = true
        }
        return changed
    }

    /// 기록된 대화 보완 (v5, 요구사항 §19) — 주제·어조·핵심 발언을 뽑는다.
    nonisolated public static func analyzeConversation(
        _ text: String, contentHash: String,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> ConversationMeta? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
            return ConversationMeta(contentHash: contentHash)
        }
        let output =
            (try? await engine.generateOneShot(
                system: Prompts.conversationSystem,
                user: "다음 대화를 분석하라.\n\n\(text)",
                maxTokens: 128,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        var topic: String?
        var tone: String?
        var statements: [String] = []
        for rawLine in output.split(separator: "\n") {
            let line = EventParser.stripListMarker(
                rawLine.trimmingCharacters(in: .whitespaces))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "주제": topic = String(value.prefix(30))
            case "어조", "분위기": tone = String(value.prefix(20))
            case "핵심":
                if statements.count < 2,
                    let quote = EventParser.validatedQuote(value, in: text)
                {
                    statements.append(String(quote.prefix(40)))
                }
            default: break
            }
        }
        return ConversationMeta(
            contentHash: contentHash, topic: topic, tone: tone, keyStatements: statements)
    }

    /// 등록 인물 ↔ 과거 사건 참여자 소급 연결 (결정적·LLM 없음, CLAUDE.md §2-5).
    ///
    /// 왜 필요한가: 추출은 **그 시점에 등록된 카드만** 참여자로 링크한다
    /// (CLAUDE.md §3). 그래서 나중에 등록된 인물은 이미 메모된 과거 사건에
    /// 영영 연결되지 못하고, 역색인이 빈 채로 남아 카드의 "최근" 줄이 나오지
    /// 않는다. 등록 때마다 전 씬을 재추출하면 LLM 비용이 등록 횟수만큼 곱해지므로,
    /// 사건 요약문의 이름 매칭으로 잇는다.
    ///
    /// 트레이드오프: 요약에 이름이 있지만 실제 참여자가 아닌 경우("서연이 민준의
    /// 편지를 읽었다"의 민준)까지 링크된다. 이름이 언급된 사건은 그 인물의
    /// 맥락으로서 여전히 유효하다고 보고 받아들인다 — 역색인에 구멍이 남는 쪽이
    /// 더 나쁘다. 기존 참여자는 지우지 않는다(추출 당시의 판단을 신뢰).
    nonisolated private static func relinkParticipants(
        sidecar: inout KnowledgeSidecar, characters: [CharacterCard]
    ) {
        guard !characters.isEmpty else { return }
        let nameIndex = EventParser.nameIndex(characters)
        for (hash, events) in sidecar.events {
            var updated = events
            for offset in updated.indices {
                let summary = updated[offset].summary
                var participants = Set(updated[offset].participants)
                for (name, id) in nameIndex where summary.contains(name) {
                    participants.insert(id)
                }
                guard participants.count != updated[offset].participants.count else { continue }
                updated[offset].participants = Array(participants)
            }
            if updated != events { sidecar.events[hash] = updated }
        }
    }

    /// 씬 하나에서 사건을 뽑는다 (PLAN §6.3, M6-5) — 깊은 패스 전용.
    ///
    /// 요약과 **별도 호출**인 이유: 요약 경로는 이미 측정·출시됐고, 사건 파싱
    /// 실패가 요약까지 죽이면 회귀다 (docs/m6-events.md 결정 3).
    /// 등록 카드가 없으면 호출 자체를 건너뛴다 — 참여자를 링크할 수 없는 사건은
    /// 역색인에 들어가지 못해 토큰만 태운다 (CLAUDE.md §5-1).
    /// 벤치가 같은 프롬프트를 쓰도록 public (요약 경로와 같은 이유).
    nonisolated public static func extractEvents(
        _ text: String, sceneHash: String, characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [StoryEvent]? {
        let nameIndex = EventParser.nameIndex(characters)
        guard !nameIndex.isEmpty else { return nil }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return []  // 요약과 같은 초미니 씬 가드 — 뽑을 사건이 없다(환각 방지)
        }
        let output =
            (try? await engine.generateOneShot(
                system: Prompts.eventSystem,
                user: Prompts.eventUser(text, names: nameIndex.keys.sorted()),
                // 5b에서 줄마다 `상태:` 필드가, v4에서 `근거:`가 붙어 길어졌다 —
                // 마지막 줄이 중간에서 잘리면 그 사건·델타를 통째로 잃는다.
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }  // 실패 — 다음 패스가 재시도
        return EventParser.parse(
            output, sceneHash: sceneHash, nameIndex: nameIndex, sceneText: text)
    }

    /// 하위 요약 묶음 → 상위 요약 (장 ≤300자 · 작품 ≤500자).
    nonisolated public enum RollupLevel { case chapter, work }

    nonisolated public static func rollup(
        _ summaries: [String], level: RollupLevel,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> String? {
        let summary =
            (try? await engine.generateOneShot(
                system: level == .chapter ? Prompts.chapterSystem : Prompts.workSystem,
                user: Prompts.rollupUser(summaries),
                maxTokens: level == .chapter ? 128 : 160,
                parameters: parameters)) ?? ""
        return summary.isEmpty ? nil : clamp(summary, to: level == .chapter ? 300 : 500)
    }

    // MARK: - 보조

    /// 커서와 씬의 UTF-16 거리 — 커서가 씬 안이면 0.
    /// internal인 이유: "가까운 씬부터 이해한다" 성질을 단위 테스트로 고정.
    nonisolated static func distance(
        from scene: DocumentOutline.Scene, to caret: Int
    ) -> Int {
        if scene.utf16Range.contains(caret) { return 0 }
        return caret < scene.utf16Range.lowerBound
            ? scene.utf16Range.lowerBound - caret
            : caret - scene.utf16Range.upperBound
    }

    /// 열·전력 시민의식 (PLAN §9) — `.serious` 이상이면 전부, 저전력이면 깊은
    /// 패스만 보류한다. 판정은 상태를 주입받는 순수 함수 — 실제 발열·저전력을
    /// 만들 수 없는 테스트도 백그라운드 3요건(게이트)의 경계를 검증할 수 있다.
    nonisolated static func gateAllows(
        deep: Bool, thermalState: ProcessInfo.ThermalState,
        lowPowerModeEnabled: Bool
    ) -> Bool {
        switch thermalState {
        case .serious, .critical: return false
        default: break
        }
        if deep, lowPowerModeEnabled { return false }
        return true
    }

    nonisolated private static func gateAllows(deep: Bool) -> Bool {
        let process = ProcessInfo.processInfo
        return gateAllows(
            deep: deep, thermalState: process.thermalState,
            lowPowerModeEnabled: process.isLowPowerModeEnabled)
    }

    /// 게이트 차단 이유 — UI가 "왜 멈췄는지"를 말해야 하기 때문 (#35).
    /// nil이면 차단 아님. 순수 함수라 게이트와 함께 테스트한다.
    nonisolated static func gateBlockReason(
        deep: Bool, thermalState: ProcessInfo.ThermalState,
        lowPowerModeEnabled: Bool
    ) -> String? {
        switch thermalState {
        case .serious, .critical: return "기기가 뜨거워요(열 상태) — 식으면 자동으로 다시 시작할 수 있어요"
        default: break
        }
        if deep, lowPowerModeEnabled { return "저전력 모드예요 — 저전력을 끄거나 나중에 다시 시도해 주세요" }
        return nil
    }

    nonisolated static func makeSnapshot(
        entryID: UUID, scope: StoryMemoryScope? = nil,
        outline: DocumentOutline, sidecar: KnowledgeSidecar,
        utterances: [Utterance], overrides: [NarrativeOverride] = [],
        body: String = "", characters: [CharacterCard] = [],
        recordedConversations: [RecordedConversation] = []
    ) -> KnowledgeSnapshot {
        // 사용자 수정 재앵커 — 씬 원문이 바뀌어 해시가 바뀐 오버라이드를 앵커
        // 스니펫으로 잇는다. 실패분은 stale로 스냅샷에 실려 UI가 알린다 (§1-5).
        let (rekeyed, stale) = NarrativeOverrides(overrides)
            .rekeyedForScenes(outline: outline, body: body)
        // 기록된 대화의 재앵커 — 원문이 수정됐으면 첫/끝 대사로 위치를 되찾는다.
        let text = body as NSString
        let anchoredRecords = recordedConversations.map {
            ConversationDetector.reanchor($0, in: text) ?? $0
        }
        // 사용자 구간 경계 수정 적용 (요구사항 §15) — 인용을 씬 원문에서 되찾아
        // 범위를 다시 잡는다. 층·시점 등 나머지 오버라이드는 스냅샷 조립이 얹는다.
        let boundedSegments = SegmentParser.applyingBoundaryOverrides(
            sidecar.segments, overrides: rekeyed, outline: outline, body: body)
        let memoryScope = scope ?? .legacy(
            documentID: WritingDocumentID(rawValue: entryID))
        let storyMemory = StoryMemorySnapshot.make(
            scope: memoryScope, outline: outline, sidecar: sidecar, body: body)
        let storyKnowledge = StoryKnowledgeProjection.make(
            scope: memoryScope, body: body, outline: outline, sidecar: sidecar,
            characters: characters, overrides: rekeyed)
        let freshSceneSummaries = Dictionary(
            uniqueKeysWithValues: storyMemory.sceneSummaries.map {
                ($0.key.rawValue, $0.value)
            })
        let freshChapterSummaries = Dictionary(
            uniqueKeysWithValues: storyMemory.chapterSummaries.values.map {
                ($0.headingPath.joined(separator: " > "), $0.summary)
            })
        return KnowledgeSnapshot(
            entryID: entryID,
            outline: outline,
            summariesByHash: freshSceneSummaries.mapValues(\.summary),
            chapterSummariesByPath: freshChapterSummaries,
            workSummary: storyMemory.workSummary?.summary,
            storyMemory: storyMemory,
            storyKnowledge: storyKnowledge,
            events: sidecar.events,
            utterances: utterances,
            sceneSummaries: freshSceneSummaries,
            insights: sidecar.insights,
            segments: boundedSegments,
            eventGraph: sidecar.eventGraph,
            plotThreadAnalysis: sidecar.plotThreads,
            recordedConversations: anchoredRecords,
            conversationMeta: sidecar.conversationMeta,
            characters: characters,
            overrides: rekeyed,
            staleOverrides: stale
        )
    }

    /// 하위 해시들의 결합 해시 — 장·작품 노드의 더티 판정 키.
    nonisolated private static func combinedHash(_ hashes: [String]) -> String {
        DocumentOutline.stableHash(hashes.joined(separator: "|"))
    }

    /// 요약 길이 상한 (PLAN §6.1) — 모델이 상한을 어겨도 저장은 규격대로.
    /// **문장 경계 절단** — prefix로 문장 중간을 자르던 것이 타임라인 텍스트
    /// 잘림의 저장 단계 원인이었다 (SentenceClamp 참조).
    nonisolated private static func clamp(_ text: String, to limit: Int) -> String {
        SentenceClamp.clamp(text, to: limit)
    }

    // MARK: - 프롬프트 (요약 피라미드, PLAN §6.1)

    nonisolated private enum Prompts {
        static let sceneSystem = """
            너는 소설 장면을 분석하는 도우미다. 주어진 장면을 읽고 아래 형식으로 \
            한 줄씩 출력한다. 인물 이름을 유지하고, 장면에 없는 내용은 지어내지 \
            않는다. 설명·머리말 없이 아래 줄들만 출력한다.

            제목: 장면 내용을 한눈에 알 수 있는 제목 (최대 20자, 번호·작품명 금지)
            요약: 일어난 일 1~2문장 (최대 150자, 문장을 끝까지 완성할 것)
            유형: 현재/회상/꿈/예상/병렬/삽입 중 하나 (기본은 현재. 장면 전체가 \
            과거 회상일 때만 회상)
            시점: 시점 인물 이름 (모르면 이 줄 생략)
            장소: 장면의 장소 (모르면 이 줄 생략)
            """

        static func sceneUser(_ text: String) -> String {
            """
            다음 장면을 분석하라.

            \(text)
            """
        }

        // MARK: 심화 추출 (v4, PLAN §6.5) — 앎·관계

        static let insightSystem = """
            너는 소설 장면에서 서사 정보를 뽑는 도우미다. 장면에 실제로 근거가 \
            있는 것만, 한 줄에 하나씩 아래 두 형식 중 맞는 것으로 출력한다. \
            해당 사항이 없는 종류는 출력하지 않는다. 종류마다 최대 3개.

            앎: 인물 태도=사실 | 근거: 원문 짧은 인용
            관계: 인물A→인물B=관계 상태 | 근거: 원문 짧은 인용

            규칙:
            - 앎의 태도는 안다/의심/오해/숨김 네 가지만 쓴다. "인물이 이 장면에서 \
            새로 알게 되거나 의심하게 된 것"만 쓴다.
            - 앎과 관계의 인물은 주어진 인물 목록에 있는 이름만 쓴다.
            - 근거 인용은 장면 원문에서 그대로 복사한 30자 이내 구절이다.
            - 설명·머리말 없이 위 형식의 줄만 출력한다.
            """

        static func insightUser(_ text: String, names: [String]) -> String {
            """
            인물 목록: \(names.isEmpty ? "(등록된 인물 없음 — 앎·관계는 출력하지 않는다)" : names.joined(separator: ", "))

            다음 장면에서 서사 정보를 뽑아라.

            \(text)
            """
        }

        // MARK: 서사 구간 분석 (v5, 요구사항 §7–§10)

        static let segmentSystem = """
            너는 소설 장면 안의 시간 이동과 관점 전환을 찾는 도우미다. 장면을 \
            읽고, 서술이 현재에서 벗어나는 구간(회상·꿈·기록·구술)이 있으면 \
            구간마다 한 줄씩 아래 형식으로 출력한다. 없으면 "없음"만 출력한다. \
            최대 4개.

            구간: 층=회상 | 시작="구간 첫 문장을 원문 그대로 복사" | \
            끝="현재로 복귀하기 직전 문장을 원문 그대로 복사" | 복귀=확인 | \
            깊이=1 | 시점=인물이름 | 화자=서술자 | 인물=이 과거의 주인 | \
            출처=기억 | 신뢰=유력

            규칙:
            - 층은 회상/짧은기억/구술/꿈/기록/재서술/예상 중 하나만 쓴다. \
            과거형 문장이 있다는 이유만으로 회상이 아니다 — 서술의 시간 자체가 \
            이동한 구간만 쓴다. 과거 사건을 한 문장으로 언급만 하고 지나가면 \
            구간이 아니다.
            - 시작·끝 인용은 장면 원문에서 글자 그대로 복사한다 (30자 이내).
            - 장면이 그 구간인 채로 끝나면 끝 항목을 생략하고 복귀=씬끝 이라고 \
            쓴다. 복귀 지점을 모르면 복귀=불확실 이라고 쓴다.
            - 회상 속의 또 다른 회상은 깊이=2로 쓴다.
            - 출처는 기억/증언/기록물/소문/꿈속/추론 중 하나. 신뢰는 확정/유력/\
            이견/불신/미상 중 하나 — 인물의 기억이나 말은 틀릴 수 있다.
            - 설명·머리말 없이 구간 줄만 출력한다.
            """

        static func segmentUser(_ text: String) -> String {
            """
            다음 장면에서 시간 이동 구간을 찾아라.

            \(text)
            """
        }

        // MARK: 사건 그래프 분석 (v5, 요구사항 §3·§6·§12·§29)

        static let eventGraphSystem = """
            너는 소설의 사건 목록에서 사건 사이의 관계를 찾는 도우미다. 번호가 \
            붙은 사건 목록을 읽고, 근거가 분명한 관계만 아래 세 형식으로 한 줄씩 \
            출력한다. 없으면 "없음"만 출력한다.

            인과: 3 -> 7 | 종류: 원인 | 이유: 왜 그런지 한 문장 (최대 50자)
            동일: 2 & 9
            시간: 4 < 1

            규칙:
            - 인과의 종류는 원인/영향/폭로/설명/모순/복선 중 하나만 쓴다.
            - 동일은 같은 사건이 다른 자리에서 다시 서술된 경우만 쓴다 (예: \
            4번의 싸움을 9번에서 다른 인물이 회상). 비슷한 사건은 동일이 아니다.
            - 시간은 본문 등장 순서와 실제 시간 순서가 다른 경우만 쓴다. \
            "4 < 1"은 4번이 1번보다 시간상 먼저라는 뜻이다. 동시는 "4 ~ 1".
            - 확실하지 않은 관계는 출력하지 않는다. 각 형식 최대 6개.
            - 설명·머리말 없이 위 형식의 줄만 출력한다.
            """

        // MARK: 플롯 스레드 추론 (v6 — Branch = PlotThread)

        static let plotThreadSystem = """
            너는 소설의 사건 목록에서 플롯 라인(이야기 갈래)을 찾는 도우미다. \
            플롯 라인 하나는 하나의 지속적인 문제·목표·갈등·미스터리·관계 변화를 \
            추적하는 사건들의 묶음이다. 번호가 붙은 사건 목록을 읽고 아래 형식으로 \
            한 줄에 플롯 하나씩 출력한다. 없으면 "없음"만 출력한다.

            플롯: 1,3,5,8 | 제목: 플롯 이름 (최대 15자) | 요약: 무엇을 추적하는지 한 문장 (최대 50자) | 해결: 8

            규칙:
            - 같은 인물이 나온다는 이유로 묶지 않는다. 같은 목표·갈등·질문을 \
            잇는 사건만 같은 플롯이다. 인물이 달라도 같은 문제를 이으면 같은 플롯이다.
            - 회상·시간 이동은 플롯 구분의 근거가 아니다.
            - 앞 사건의 결과를 뒤 사건이 이어받으면(인과) 같은 플롯일 가능성이 높다.
            - 한 사건이 여러 플롯에 속할 수 있다 — 두 이야기가 만나는 사건이다.
            - "해결"은 그 플롯의 질문·갈등이 실제로 끝난 사건 번호만 쓴다. 없으면 생략.
            - 사건 2개 이상인 플롯만 출력한다. 확실하지 않으면 출력하지 않는다. 최대 5개.
            - 설명·머리말 없이 위 형식의 줄만 출력한다.
            """

        // MARK: 기록된 대화 보완 (v5, 요구사항 §19)

        static let conversationSystem = """
            너는 소설 속 대화를 분석하는 도우미다. 대화를 읽고 아래 형식으로 \
            한 줄씩 출력한다. 설명·머리말 없이 아래 줄만 출력한다.

            주제: 대화의 주제 (최대 25자)
            어조: 대화의 정서적 분위기 (최대 15자)
            핵심: 가장 중요한 대사 하나를 원문 그대로 복사 (최대 40자)
            """

        static let chapterSystem = """
            너는 소설의 장(章)을 요약하는 도우미다. 주어진 장면 요약들을 묶어 \
            줄거리를 한국어 2~3문장(최대 300자)으로 요약한다. 인물 이름을 \
            유지하고, 설명·머리말 없이 요약문만 출력한다.
            """

        static let workSystem = """
            너는 소설 전체 줄거리를 요약하는 도우미다. 주어진 요약들을 묶어 \
            지금까지의 이야기를 한국어 3~4문장(최대 500자)으로 요약한다. 인물 \
            이름을 유지하고, 설명·머리말 없이 요약문만 출력한다.
            """

        static func rollupUser(_ summaries: [String]) -> String {
            """
            다음 요약들을 묶어 하나의 줄거리로 요약하라.

            \(summaries.map { "- \($0)" }.joined(separator: "\n"))
            """
        }

        // MARK: 사건 추출 (PLAN §6.3) — JSON 대신 줄 형식 (docs/m6-events.md 결정 4)

        static let eventSystem = """
            너는 소설 장면에서 사건을 뽑는 도우미다. 장면에서 실제로 일어난 일만 \
            중요한 순서로 최대 3개까지, 한 줄에 하나씩 아래 형식으로 출력한다.

            사건요약(최대 80자, 문장을 끝까지 완성) | 참여: 인물이름들 | 중요도: 1~5 | \
            상태: 인물 필드=값; 인물 필드=값 | 근거: 원문 짧은 인용

            중요도 기준 (요구사항: 숫자를 감으로 매기지 않는다):
            5 = 갈등·관계·목표가 뒤집히거나, 비밀·죽음처럼 이후 이야기의 방향을 \
            바꾸는 사건
            4 = 중요한 결정, 새로운 정보의 공개, 이후 사건의 직접 원인
            3 = 이야기가 앞으로 나아가는 보통 사건
            2 = 분위기·일상 묘사 속의 작은 일
            1 = 스쳐 가는 사소한 일

            상태는 이 사건으로 실제로 **바뀐** 인물 상태만 쓴다. 필드는 위치, 감정, \
            관계, 목표, 생사 다섯 가지만 쓴다. 값은 40자 이내로 짧게 쓴다. \
            바뀐 상태가 없으면 상태 항목을 통째로 생략한다. \
            근거는 장면 원문에서 그대로 복사한 30자 이내 구절이다.

            규칙: 주어진 인물 목록에 있는 이름만 참여와 상태에 쓴다. 장면에 없는 \
            일을 지어내지 않는다. 설명·머리말 없이 사건 줄만 출력한다.
            """

        /// 등록 인물 목록을 함께 준다 — 모델이 지어낸 인물은 파서가 버리지만
        /// (EventParser.resolve), 목록을 미리 주면 애초에 덜 지어낸다.
        static func eventUser(_ text: String, names: [String]) -> String {
            """
            인물 목록: \(names.joined(separator: ", "))

            다음 장면에서 사건을 뽑아라.

            \(text)
            """
        }
    }
}
