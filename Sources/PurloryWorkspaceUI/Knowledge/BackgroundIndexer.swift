import Observation
import Combine
import AppKit
import Foundation
import os
import PurloryFoundation
import PurloryDocumentEngine
import PurloryInference
import PurloryIntelligence

/// Prepares derived story memory outside prediction. Work is scoped, cancellable,
/// incremental and subordinate to foreground editing, power and memory pressure.
@Observable
@MainActor
public final class BackgroundIndexer {
    // Native consumers need synchronous value events before ownership changes.
    private let _snapshotEvents = CurrentValueSubject<KnowledgeSnapshot?, Never>(nil)
    var snapshotChanges: AnyPublisher<KnowledgeSnapshot?, Never> { _snapshotEvents.eraseToAnyPublisher() }
    private let _snapshotGenerationEvents = CurrentValueSubject<Int, Never>(0)
    var snapshotGenerationChanges: AnyPublisher<Int, Never> { _snapshotGenerationEvents.eraseToAnyPublisher() }
    private let _manualPhaseEvents = CurrentValueSubject<PassPhase, Never>(.idle)
    var manualPhaseChanges: AnyPublisher<PassPhase, Never> { _manualPhaseEvents.eraseToAnyPublisher() }
    private let _continuityCandidatesEvents = CurrentValueSubject<[ContinuityCandidate], Never>([])
    var continuityCandidatesChanges: AnyPublisher<[ContinuityCandidate], Never> { _continuityCandidatesEvents.eraseToAnyPublisher() }


    /// 최신 지식 스냅샷 — `CompletionController.knowledgeProvider`가 pull한다.
    public private(set) var snapshot: KnowledgeSnapshot? { willSet { _snapshotEvents.send(newValue) } }
    /// 진행 중 패스 표시 (툴바 칩 등 UI 관찰용 — 조용한 UI 원칙상 필수는 아니다).
    public private(set) var isIndexing = false
    /// Repeated idle preemption must not invalidate presentation readers.
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

    public private(set) var manualPhase: PassPhase = .idle { willSet { _manualPhaseEvents.send(newValue) } }
    /// 사용자 요청 패스의 소유권 토큰 — finish/cancel 가드 (#82와 같은 규약).
    @ObservationIgnored private var manualPassToken: Int?
    /// 시작 시점 스냅샷 세대 — "새로 읽은 것이 있나" 판정 기준.
    @ObservationIgnored private var snapshotGenerationAtManualStart = 0
    @ObservationIgnored private var manualProcessedAny = false
    @ObservationIgnored private var manualDirtyTotal = 0
    @ObservationIgnored private var transientClearTask: Task<Void, Never>?

    /// 스냅샷 세대 — 실제 발행마다 증가하는 싸구려 신분증 (#48). 지식 뷰들이
    /// 캐시 키로 쓴다: 스냅샷 전체 동등 비교(사건 수천 개 배열)를 매 패스
    /// 반복하는 대신 정수 비교로 "바뀌었나"를 판정한다.
    public private(set) var snapshotGeneration = 0 { willSet { _snapshotGenerationEvents.send(newValue) } }
    /// 인물 감지 후보 (M6, PLAN §7) — 감지는 자동, **등록은 사용자 확인**
    /// (CLAUDE.md §3). 바이블 팝오버가 전부 나열해 검토받는다 (M6-8).
    public private(set) var characterCandidates: [CharacterDetector.Candidate] = []
    /// 후보가 어느 문서 것인지 — 문서 전환 시 낡은 후보를 보여주지 않기 위한 짝.
    public private(set) var candidatesEntryID: UUID?
    /// 일관성 경고 (M7) — 스냅샷과 같은 주기로 갱신. **비침습**: 사이드바
    /// 배지·목록만, 본문엔 아무것도 긋지 않는다 (ConsistencyChecker 참조).
    public private(set) var warnings: [ConsistencyWarning] = []
    public private(set) var continuityCandidates: [ContinuityCandidate] = [] { willSet { _continuityCandidatesEvents.send(newValue) } }

    /// Identical findings do not invalidate warning readers.
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

    public private(set) var metrics: KnowledgeMetrics?

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
    @ObservationIgnored public var caretProvider: (() -> Int?)?

    @ObservationIgnored private var memoryPressurePaused = false
    @ObservationIgnored private var profileTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var profileGeneration = 0
    private static let memoryPressureReason = "메모리가 부족해 읽기를 쉬고 있어요 — 여유가 생기면 다시 시도해 주세요"

    /// Recovery only admits a later edit, deactivation, or explicit request; it never reloads a model.
    public func setMemoryPressurePaused(_ paused: Bool) {
        guard memoryPressurePaused != paused else { return }
        memoryPressurePaused = paused
        if paused {
            setContinuityCandidates([])
            let hadManualWork = manualPassToken != nil
            cancelActiveWork()
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
    @ObservationIgnored private var documentProvider: (() -> ProjectDocumentSnapshot?)?
    @ObservationIgnored private var writerReader = WriterDocumentReader()
    @ObservationIgnored private var observedRuntimeIdentity: ProjectRuntimeIdentity?
    public private(set) var snapshotRuntimeIdentity: ProjectRuntimeIdentity?
    /// One active project's already-loaded derived values. Edits revalidate them against
    /// the new body in background without adding sidecar reads to the typing path.
    @ObservationIgnored private var preparedProjectSidecar: KnowledgeSidecar?
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
    @ObservationIgnored private var resignActiveObserver: NSObjectProtocol?
    @ObservationIgnored private var foregroundCompletionBusy = false
    @ObservationIgnored private var pendingIdleReschedule = false
    @ObservationIgnored private var activeHydrateEntryID: UUID?
    @ObservationIgnored private var activeHydrateForce = false
    @ObservationIgnored private var pendingHydrateEntryID: UUID?
    @ObservationIgnored private var pendingHydrateForce = false

    public func setForegroundCompletionBusy(_ busy: Bool) {
        foregroundCompletionBusy = busy
        originalNamePreparation.setForegroundBusy(busy)
        if busy {
            // Yield background indexing/profiling immediately so foreground Ghost never contends on GPU,
            // while preserving pending idle work and in-flight hydration to resume once Ghost finishes.
            if !memoryPressurePaused {
                if fastTimer != nil || deepTimer != nil || (passTask != nil && manualPassToken == nil) {
                    pendingIdleReschedule = true
                }
                if hydrateTask != nil, let entryID = activeHydrateEntryID {
                    pendingHydrateEntryID = entryID
                    pendingHydrateForce = pendingHydrateForce || activeHydrateForce
                }
            }
            cancelProfiles()
            passGeneration += 1
            hydrateGeneration += 1
            fastTimer?.cancel()
            fastTimer = nil
            deepTimer?.cancel()
            deepTimer = nil
            hydrateTask?.cancel()
            hydrateTask = nil
            activeHydrateEntryID = nil
            activeHydrateForce = false
            passTask?.cancel()
            passTask = nil
            manualPassToken = nil
            if case .queued = manualPhase { manualPhase = .idle }
            else if case .reading = manualPhase { manualPhase = .idle }
            setIsIndexing(false)
            return
        }
        guard !memoryPressurePaused else { return }
        let shouldReschedule = pendingIdleReschedule
        pendingIdleReschedule = false
        let hydrateEntryID = pendingHydrateEntryID
        let hydrateForce = pendingHydrateForce
        pendingHydrateEntryID = nil
        pendingHydrateForce = false
        if let hydrateEntryID {
            hydrateIfNeeded(entryID: hydrateEntryID, force: hydrateForce)
        }
        if shouldReschedule, settings.autocompleteEnabled {
            armIdleTimers()
        }
    }
    private func prepareOriginalNameAnchors() {
        guard !memoryPressurePaused, originalNameAnchorsEnabled, let document = currentDocument(), document.isFiction else {
            originalNamePreparation.shutdown()
            return
        }
        originalNamePreparation.prepare(source: document.source, documentID: document.id,
            scope: document.scope, runtimeIdentity: document.runtimeIdentity, characters: document.characters)
    }

    /// Knowledge-specific metadata stays in the reader adapter, outside ProjectSession.
    private struct DocumentInput {
        let id: UUID
        let scope: StoryMemoryScope
        let runtimeIdentity: ProjectRuntimeIdentity?
        let source: DocumentSource
        var body: String { source.string }
        let isFiction: Bool
        let characters: [CharacterCard]
        let overrides: [NarrativeOverride]
        let recorded: [RecordedConversation]
        let rejectedNames: [String]
    }

    private func currentDocument() -> DocumentInput? {
        guard let document = documentProvider?(),
            let writer = try? writerReader.read(document) else { return nil }
        let key = document.identity.key
        return DocumentInput(
            id: key.documentID.rawValue,
            scope: .project(projectID: key.projectID, documentID: key.documentID),
            runtimeIdentity: document.identity, source: document.source,
            isFiction: document.mode == .fiction,
            characters: writer.characters, overrides: writer.narrativeOverrides,
            recorded: writer.recordedConversations, rejectedNames: writer.rejectedCharacterNames)
    }

    @ObservationIgnored private var fastTimer: Task<Void, Never>?
    @ObservationIgnored private var deepTimer: Task<Void, Never>?
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    /// 패스 소유권 토큰 — 선점(새 noteChange·requestPass·전체 다시 읽기)마다
    /// 올라간다. 늦게 끝난 이전 작업은 자기 토큰이 현재와 같을 때만 상태를
    /// 건드린다 (이슈 #82).
    @ObservationIgnored public private(set) var passGeneration = 0
    /// 현재 패스가 읽고 있는 문서·본문 지문 — 발행 가드의 entryID/hash 절반.
    @ObservationIgnored public private(set) var passEntryID: UUID?
    @ObservationIgnored public private(set) var passBodyHash: String?
    @ObservationIgnored public private(set) var passScope: StoryMemoryScope?

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

    @ObservationIgnored var _testGateStateProvider:
        (@Sendable () -> (thermalState: ProcessInfo.ThermalState, lowPowerModeEnabled: Bool))?

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
        // App deactivation acts as an idle signal to trigger a deep pass.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.startPass(deep: true) }
        }
    }

    /// ContentView가 1회 배선 — 패스 시점에 활성 문서를 pull하기 위한 약참조.
    public func attach(documentProvider: @escaping () -> ProjectDocumentSnapshot?) {
        prepareForProjectTransition()
        self.documentProvider = documentProvider
    }

    /// Cancels in-flight tasks and timers without removing lifecycle observers so recoverable
    /// pauses (such as memory pressure) can resume listening when pressure clears.
    private func cancelActiveWork() {
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
        activeHydrateEntryID = nil
        activeHydrateForce = false
        pendingHydrateEntryID = nil
        pendingHydrateForce = false
        pendingIdleReschedule = false
        passTask?.cancel()
        passTask = nil
        resetTask?.cancel()
        resetTask = nil
        setIsIndexing(false)
    }

    /// 앱 종료 직전 호출 — 유휴 타이머와 진행 패스를 접어, 엔진의 드레인이
    /// 길어지지 않게 한다 (이슈 #65 Gate 0 teardown 세그폴트 수정). 종료 시점의
    /// 백그라운드 이해는 어차피 버려질 결과다 — 원문은 flush로 이미 안전하다.
    public func shutdown() {
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        cancelActiveWork()
    }

    private func armIdleTimers() {
        fastTimer?.cancel()
        fastTimer = nil
        deepTimer?.cancel()
        deepTimer = nil
        guard !memoryPressurePaused, settings.autocompleteEnabled else { return }
        if foregroundCompletionBusy {
            pendingIdleReschedule = true
            return
        }
        fastTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.fastPassIdle)
            guard !Task.isCancelled else { return }
            self?.fastTimer = nil
            self?.startPass(deep: false)
        }
        deepTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.deepPassIdle)
            guard !Task.isCancelled else { return }
            self?.deepTimer = nil
            self?.startPass(deep: true)
        }
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
        cancelProfiles()
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

        // 자동완성이 꺼져 있으면 타이머조차 감지 않는다 — 어차피 패스가 거부되고,
        // 키 입력 경로에 태스크 생성 비용을 남길 이유가 없다 (랙 진단의 대조군:
        // 스위치를 끄면 백그라운드 이해 관련 작업이 문자 그대로 0이어야 한다).
        // (웜 로드는 위에서 이미 했다 — 읽기 전용이라 스위치와 무관.)
        armIdleTimers()
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
        activeHydrateEntryID = nil
        activeHydrateForce = false
        pendingHydrateEntryID = nil
        pendingHydrateForce = false
        pendingIdleReschedule = false
        fastTimer?.cancel()
        fastTimer = nil
        deepTimer?.cancel()
        deepTimer = nil
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

    @ObservationIgnored private var hydrateTask: Task<Void, Never>?
    /// hydrate 소유권 토큰 — 새 요청마다 올라가 늦은 발행을 무효화 (#82).
    @ObservationIgnored public private(set) var hydrateGeneration = 0

    /// 활성 문서의 스냅샷이 없으면 사이드카에서 만든다 — 결정적·읽기 전용이라
    /// 게이트(열·저전력·자동완성) 대상이 아니다. 사이드카가 비어 있어도
    /// 발행한다: 씬 분할·"아직 안 읽음" 상태가 즉시 보이는 것 자체가 가치다.
    /// `force`: 사용자 수정(오버라이드) 변경 시 — 이미 스냅샷이 있어도 다시
    /// 조립해 수정이 즉시 보이게 한다 (LLM 없음, 결정적 재조립).
    private func hydrateIfNeeded(entryID: UUID, force: Bool = false) {
        guard !memoryPressurePaused else { return }
        if foregroundCompletionBusy {
            pendingHydrateEntryID = entryID
            pendingHydrateForce = pendingHydrateForce || force
            return
        }
        guard let entry = currentDocument(), entry.id == entryID else { return }
        let scope = entry.scope
        let runtimeIdentity = entry.runtimeIdentity
        guard force || snapshot?.storyMemory?.scope != scope
            || snapshotRuntimeIdentity != runtimeIdentity
        else { return }
        guard entry.isFiction else { return }
        let source = entry.source
        let waitForIdle = !force && runtimeIdentity != nil
            && (snapshot?.storyMemory?.scope == scope || hydrateTask != nil)
        let characters = entry.characters
        let overrides = entry.overrides
        let recorded = entry.recorded
        let prepared = !force && runtimeIdentity != nil && preparedProjectSidecar?.scope == scope
            ? preparedProjectSidecar : nil

        hydrateGeneration += 1
        let token = hydrateGeneration
        hydrateTask?.cancel()
        activeHydrateEntryID = entryID
        activeHydrateForce = force
        // 파싱·디스크 읽기를 메인에서 떼어낸다 (30만 자 파싱이 메인을 막지 않게).
        let persistence = sidecarPersistence
        hydrateTask = Task.detached(priority: .utility) { [weak self] in
            func clearActiveHydrate() async {
                await MainActor.run { [weak self] in
                    guard let self, self.hydrateGeneration == token else { return }
                    self.hydrateTask = nil
                    self.activeHydrateEntryID = nil
                    self.activeHydrateForce = false
                }
            }
            // Repeated typing cancels preparation before any whole-source read. Load/recovery
            // still hydrates immediately; foreground completion retains its existing priority.
            if waitForIdle {
                do { try await Task.sleep(for: .milliseconds(200)) } catch {
                    await clearActiveHydrate()
                    return
                }
            }
            guard !Task.isCancelled else { await clearActiveHydrate(); return }
            let body = source.string
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await clearActiveHydrate()
                return
            }
            let outline = DocumentOutline.parse(body)
            guard !outline.scenes.isEmpty, !Task.isCancelled else {
                await clearActiveHydrate()
                return
            }
            let loadStart = CFAbsoluteTimeGetCurrent()
            let sidecar: KnowledgeSidecar
            if let prepared {
                sidecar = prepared
            } else {
                sidecar = await persistence.load(scope: scope)
            }
            guard !Task.isCancelled, sidecar.scope == scope else {
                await clearActiveHydrate()
                return
            }
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
                self.hydrateTask = nil
                self.activeHydrateEntryID = nil
                self.activeHydrateForce = false
                guard let current = self.currentDocument(), current.id == entryID,
                    current.scope == scope, current.runtimeIdentity == runtimeIdentity,
                    current.source.isSameVersion(as: source) || current.body == body
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
        if foregroundCompletionBusy {
            if !userInitiated, settings.autocompleteEnabled {
                pendingIdleReschedule = true
            }
            return
        }
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
        let gateStateProvider = _testGateStateProvider
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
                // 늦은 이전 작업은 후보 발표조차 하지 않는다 (#82).
                guard owned() else { superseded = true; return }
                if self.characterCandidates != candidates {
                    self.characterCandidates = candidates
                }
                if self.candidatesEntryID != entryID { self.candidatesEntryID = entryID }
            }
            if superseded {
                await MainActor.run { self.finishPass(token: token) }
                return
            }
            let liveCharacters = characters
            let blockedReasonBox = OSAllocatedUnfairLock<String?>(initialState: nil)
            await Self.runPass(
                deep: deep, scope: scope, entryID: entryID, body: body,
                parameters: parameters, engine: engine,
                persistence: persistence,
                liveEntryIDs: [], characters: liveCharacters,
                overrides: overrides, recordedConversations: recorded,
                caretUTF16: caret,
                gateStateProvider: gateStateProvider
            ) { snapshot in
                // Run consistency checks off the main thread using liveCharacters (including auto-registered cards).
                let warnings = ConsistencyChecker.check(
                    snapshot: snapshot, characters: liveCharacters, source: body)
                let candidates = ContinuityCandidate.prepare(snapshot: snapshot, warnings: warnings, scope: identity.scope, source: body)
                await MainActor.run {
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
                blockedReasonBox.withLock { $0 = reason }
                Task { @MainActor in
                    guard self.manualPassToken == token, self.owns(identity) else { return }
                    if self.manualPhase != .blocked(reason: reason) {
                        self.manualPhase = .blocked(reason: reason)
                    }
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
                if let reason = blockedReasonBox.withLock({ $0 }),
                    self.manualPassToken == token, self.owns(identity),
                    self.manualPhase != .blocked(reason: reason)
                {
                    self.manualPhase = .blocked(reason: reason)
                }
                self.finishManualPhase(identity: identity)
                self.finishPass(token: token)
            }
        }
    }

    // MARK: - 인물 후보 확인 (등록은 사용자, CLAUDE.md §3)

    /// HIGH 신뢰 후보의 자동 등록 (요구사항 §16) — 사용자 확인 없이 카드를
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
            let note = await KnowledgeAnalysisPipeline.profileCharacter(
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


    // MARK: - Detached Pipeline & Snapshot Facade

    public struct SceneAnalysis: Equatable, Sendable {
        public var title: String?
        public var summary: String
        public var narrativeType: String?
        public var pov: String?
        public var location: String?
    }

    nonisolated public enum RollupLevel { case chapter, work }
    nonisolated public static let maxSummaryCharacters = 160

    nonisolated static func runPass(
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
        gateStateProvider: (@Sendable () -> (thermalState: ProcessInfo.ThermalState, lowPowerModeEnabled: Bool))? = nil,
        publish: @Sendable @escaping (KnowledgeSnapshot) async -> Void,
        publishMetrics: @Sendable @escaping (KnowledgeMetrics) -> Void = { _ in },
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        onBlocked: (@Sendable (String) -> Void)? = nil,
        commit: @Sendable @escaping (KnowledgeSidecar, Set<String>?) async -> Bool = { _, _ in true }
    ) async {
        await KnowledgeAnalysisPipeline.runPass(
            deep: deep, scope: scope, entryID: entryID, body: body,
            parameters: parameters, engine: engine, persistence: persistence,
            liveEntryIDs: liveEntryIDs, characters: characters,
            overrides: overrides, recordedConversations: recordedConversations,
            caretUTF16: caretUTF16, gateStateProvider: gateStateProvider,
            publish: publish, publishMetrics: publishMetrics,
            progress: progress, onBlocked: onBlocked, commit: commit
        )
    }

    nonisolated public static func analyzeScene(
        _ text: String, engine: CompletionEngine, parameters: CompletionParameters
    ) async -> SceneAnalysis? {
        await KnowledgeAnalysisPipeline.analyzeScene(text, engine: engine, parameters: parameters)
    }

    nonisolated public static func summarizeScene(
        _ text: String, engine: CompletionEngine, parameters: CompletionParameters
    ) async -> String? {
        await KnowledgeAnalysisPipeline.summarizeScene(text, engine: engine, parameters: parameters)
    }

    nonisolated static func parseSceneAnalysis(_ output: String) -> SceneAnalysis? {
        KnowledgeAnalysisPipeline.parseSceneAnalysis(output)
    }

    nonisolated public static func extractInsights(
        _ text: String, sceneHash: String, characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> SceneInsights? {
        await KnowledgeAnalysisPipeline.extractInsights(
            text, sceneHash: sceneHash, characters: characters, engine: engine, parameters: parameters)
    }

    nonisolated public static func analyzeSegments(
        _ text: String, sceneHash: String,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [NarrativeSegment]? {
        await KnowledgeAnalysisPipeline.analyzeSegments(
            text, sceneHash: sceneHash, engine: engine, parameters: parameters)
    }

    nonisolated public static func analyzeEventGraph(
        events: [StoryEvent], characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> EventGraphParser.Result? {
        await KnowledgeAnalysisPipeline.analyzeEventGraph(
            events: events, characters: characters, engine: engine, parameters: parameters)
    }

    nonisolated public static func analyzePlotThreads(
        events: [StoryEvent], characters: [CharacterCard],
        causalLinks: [CausalLink],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [PlotThread]? {
        await KnowledgeAnalysisPipeline.analyzePlotThreads(
            events: events, characters: characters, causalLinks: causalLinks,
            engine: engine, parameters: parameters)
    }

    nonisolated static func uniqueEventsForAnalysis(
        _ events: [StoryEvent], limit: Int = 40
    ) -> [StoryEvent] {
        KnowledgeAnalysisPipeline.uniqueEventsForAnalysis(events, limit: limit)
    }

    nonisolated static func clearAnalysesBelowThreshold(
        sidecar: inout KnowledgeSidecar, uniqueEventCount: Int
    ) -> Bool {
        KnowledgeAnalysisPipeline.clearAnalysesBelowThreshold(
            sidecar: &sidecar, uniqueEventCount: uniqueEventCount)
    }

    nonisolated public static func analyzeConversation(
        _ text: String, contentHash: String,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> ConversationMeta? {
        await KnowledgeAnalysisPipeline.analyzeConversation(
            text, contentHash: contentHash, engine: engine, parameters: parameters)
    }

    nonisolated public static func extractEvents(
        _ text: String, sceneHash: String, characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [StoryEvent]? {
        await KnowledgeAnalysisPipeline.extractEvents(
            text, sceneHash: sceneHash, characters: characters, engine: engine, parameters: parameters)
    }

    nonisolated public static func rollup(
        _ summaries: [String], level: RollupLevel,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> String? {
        await KnowledgeAnalysisPipeline.rollup(
            summaries, level: level, engine: engine, parameters: parameters)
    }

    nonisolated static func measure(
        sidecar: KnowledgeSidecar, sceneCount: Int,
        loadMs: Double, deriveMs: Double, saveMs: Double = 0
    ) -> KnowledgeMetrics {
        KnowledgeSnapshotAssembler.measure(
            sidecar: sidecar, sceneCount: sceneCount,
            loadMs: loadMs, deriveMs: deriveMs, saveMs: saveMs)
    }

    nonisolated static func distance(from scene: DocumentOutline.Scene, to caret: Int) -> Int {
        KnowledgeSnapshotAssembler.distance(from: scene, to: caret)
    }

    nonisolated static func gateAllows(
        deep: Bool, thermalState: ProcessInfo.ThermalState, lowPowerModeEnabled: Bool
    ) -> Bool {
        KnowledgeSnapshotAssembler.gateAllows(
            deep: deep, thermalState: thermalState, lowPowerModeEnabled: lowPowerModeEnabled)
    }

    nonisolated static func gateBlockReason(
        deep: Bool, thermalState: ProcessInfo.ThermalState, lowPowerModeEnabled: Bool
    ) -> String? {
        KnowledgeSnapshotAssembler.gateBlockReason(
            deep: deep, thermalState: thermalState, lowPowerModeEnabled: lowPowerModeEnabled)
    }

    nonisolated static func makeSnapshot(
        entryID: UUID, scope: StoryMemoryScope? = nil,
        outline: DocumentOutline, sidecar: KnowledgeSidecar,
        utterances: [Utterance], overrides: [NarrativeOverride] = [],
        body: String = "", characters: [CharacterCard] = [],
        recordedConversations: [RecordedConversation] = []
    ) -> KnowledgeSnapshot {
        KnowledgeSnapshotAssembler.makeSnapshot(
            entryID: entryID, scope: scope, outline: outline, sidecar: sidecar,
            utterances: utterances, overrides: overrides, body: body,
            characters: characters, recordedConversations: recordedConversations)
    }
}
