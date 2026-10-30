import Foundation
import SwiftUI

/// 고스트 텍스트 자동완성 오케스트레이터 (M3, PLAN §4·§5).
///
/// `PurloryTextView`에서 편집/커서 이벤트를 받아:
/// **디바운스 → 게이트(IME 조합·문단 끝·컨텍스트 유무) → `CompletionEngine` 호출
/// → `suggestion` 발행**. 새 입력·커서 이동·Esc는 제안 폐기 + in-flight 취소.
///
/// 게이트 규칙:
/// - `hasMarkedText`(한글 조합 중)면 절대 트리거하지 않는다 (PLAN §2).
/// - 커서 뒤~문단 끝에 내용이 있으면 트리거하지 않는다 — 고스트를 본문과
///   겹쳐 그리지 않기 위한 MVP 단순화 (docs/m3-ghost-text.md 결정 사항).
@MainActor
public final class CompletionController: ObservableObject {

    /// 모델 준비 상태 — ContentView 상태 바 표시용 (M4).
    public enum EngineState: Equatable {
        case idle
        /// 허브 다운로드 진행률 0...1.
        case downloading(Double)
        /// 다운로드 완료, 가중치 메모리 로드 중.
        case loading
        case ready
        case failed(String)
    }

    /// 현재 고스트로 띄울 제안. nil이면 없음.
    @Published public private(set) var suggestion: String?
    @Published public private(set) var engineState: EngineState = .idle
    /// 최근 제안의 생성 지연(디바운스 제외) — 상태 바 표시용.
    @Published public private(set) var lastLatency: TimeInterval?
    /// 최근 예측이 실제로 참고한 컨텍스트 (요구사항 §17 인스펙터) — 조립기가
    /// 프롬프트를 만들며 남긴 기록이라 프롬프트와 항상 일치한다. 별도 프리뷰
    /// 데이터가 아니다. 소속 문서(entryID)가 활성 문서와 다르면 인스펙터가
    /// 숨긴다 (이슈 #8). 쓰기는 모듈 내부(테스트 포함)로 제한.
    @Published public internal(set) var lastContextReport: ContextReport?

    /// 문서 전환 알림 — 이전 문서의 예측·리포트를 즉시 무효화한다 (이슈 #8).
    /// A 작품 예측 도중 B로 전환하면 세대가 올라 늦은 결과가 폐기되고, 고스트와
    /// 리포트도 A 것이 화면에 남지 않는다.
    public func noteDocumentSwitch(to entryID: UUID) {
        if let current = lastContextReport, current.entryID != entryID {
            lastContextReport = nil
        }
        invalidate()
    }

    private var runtimeIdentity: ProjectRuntimeIdentity?

    /// The transition barrier runs before the session publishes the next identity.
    public func prepareForProjectTransition() {
        runtimeIdentity = nil
        lastContextReport = nil
        dismissConversationSuggestion(remember: false)
        dismissedConversationHashes.removeAll()
        invalidate()
    }

    public func noteDocumentSwitch(to identity: ProjectRuntimeIdentity) {
        guard runtimeIdentity != identity else { return }
        if runtimeIdentity?.key != identity.key {
            dismissConversationSuggestion(remember: false)
            dismissedConversationHashes.removeAll()
        }
        runtimeIdentity = identity
        lastContextReport = nil
        invalidate()
    }

    public func noteDocumentChange(_ snapshot: ProjectDocumentSnapshot) {
        if runtimeIdentity?.key == snapshot.identity.key, retainSuggestionOnNextEdit {
            runtimeIdentity = snapshot.identity
            lastContextReport = nil
            invalidate(preservingSuggestion: true)
            return
        }
        noteDocumentSwitch(to: snapshot.identity)
    }
    /// 제안 요청이 예약·진행 중인가 — 툴바 칩의 "예측 중" 표시용 (에디터 v3).
    @Published public private(set) var isPredicting = false

    /// 고스트 렌더 뷰로의 직통 알림 — `PurloryTextView.Coordinator`가 연결한다.
    public var suggestionDidChange: ((String?) -> Void)?

    // MARK: 긴 문단 나누기 (docs/editor-paragraph-split.md)

    /// 현재 문서의 긴 산문 문단 감지 결과 — 툴바의 조용한 표시가 관찰한다.
    /// `count > 0`일 때만 표시가 나타난다(대상 없으면 아무 UI도 없음).
    /// 문서 로드 때 1회 계산 → 키 입력 경로에 O(문서)를 넣지 않는다.
    @Published public private(set) var longParagraph: LongParagraphInfo = .none

    public struct LongParagraphInfo: Equatable, Sendable {
        public var count: Int
        public var maxLength: Int
        public var typicalLength: Int
        public static let none = LongParagraphInfo(count: 0, maxLength: 0, typicalLength: 0)
        /// "보통 문단의 N배" — 0으로 나눔 방지, 최소 1배.
        public var ratio: Int { typicalLength > 0 ? max(1, maxLength / typicalLength) : 0 }
    }

    /// 에디터가 배선하는 감지·실행 다리 (`knowledgeProvider`와 같은 패턴).
    public var detectLongParagraphs: (() -> LongParagraphInfo)?
    /// 실행 → 나눈 문단 수. 성공 후 감지를 갱신한다.
    public var splitLongParagraphs: (() -> Int)?

    /// 감지를 다시 계산해 발행한다 — 문서 로드·분할 직후 에디터가 호출.
    public func refreshLongParagraphDetection() {
        longParagraph = detectLongParagraphs?() ?? .none
    }

    /// 툴바의 "문단 나누기" 실행 → 감지 갱신(대상이 사라져 표시가 숨는다).
    public func performLongParagraphSplit() {
        _ = splitLongParagraphs?()
        refreshLongParagraphDetection()
    }

    // MARK: - 대화 기록 제안 (요구사항 §18–§20)

    /// 현재 떠 있는 「이 대화를 기록할까요?」 제안 — 범위는 에디터 스토리지
    /// 좌표다 (감지가 에디터 프리픽스에서 돌기 때문). nil이면 없음.
    @Published public private(set) var conversationSuggestion: ConversationDetector.Block?
    /// 에디터(BlockTextView)로의 직통 알림 — 은은한 하이라이트·인라인 pill 렌더.
    public var conversationSuggestionDidChange: ((ConversationDetector.Block?) -> Void)?
    /// 기록 실행 다리 — ContentView가 스토어(재앵커 포함)로 배선한다. 핸들러가
    /// 없으면 승인해도 durable decision을 만들 수 없으므로 affordance 자체를 끈다.
    public var onRecordConversation: ((RecordedConversation) -> Void)? {
        didSet {
            guard onRecordConversation == nil else { return }
            conversationTask?.cancel()
            conversationTask = nil
            clearConversationSuggestion()
        }
    }
    /// 이미 기록된 블록 해시 제공자 — 같은 대화를 다시 제안하지 않는다.
    public var recordedConversationHashesProvider: (() -> Set<String>)?

    /// 감지 유휴 대기 — 고스트 디바운스보다 길다: 제안은 "대화를 다 쓰고 잠시
    /// 멈췄을 때"만 떠야 한다 (요구사항 §18·§20, 조용한 UI).
    nonisolated static let conversationIdle: Duration = .milliseconds(1_500)

    private var conversationTask: Task<Void, Never>?
    private var conversationSuggestionIdentity: ProjectRuntimeIdentity?
    /// 닫힌(Esc·계속 입력) 블록 해시 — 같은 내용을 다시 묻지 않는다. 대화가
    /// 이어져 내용이 바뀌면 해시가 바뀌어 다시 제안된다.
    private var dismissedConversationHashes: Set<String> = []

    /// 편집 후 유휴에 대화 블록을 감지한다 — 소설에서만, 결정적·LLM 없음
    /// (요구사항 §19 실시간 경로). 감지 자체도 유휴 태스크 안에서 돌므로
    /// 키 입력 경로 비용은 태스크 예약뿐이다 (요구사항 §34).
    private func scheduleConversationDetection(prefix: String, caretLocation: Int) {
        conversationTask?.cancel()
        conversationTask = nil
        guard onRecordConversation != nil,
            currentDocumentContext()?.kind == .novel
        else { return }
        let capturedIdentity = projectDocumentProvider?()?.identity
        conversationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.conversationIdle)
            guard !Task.isCancelled, let self, self.onRecordConversation != nil,
                capturedIdentity == self.projectDocumentProvider?()?.identity else { return }
            let text = prefix as NSString
            guard var block = ConversationDetector.blockEnding(at: text.length, in: text)
            else { return }
            // 프리픽스 좌표 → 스토리지 절대 좌표.
            let prefixStart = caretLocation - text.length
            block.utf16Range =
                (block.utf16Range.lowerBound + prefixStart)..<(block.utf16Range.upperBound + prefixStart)
            guard !self.dismissedConversationHashes.contains(block.contentHash),
                self.recordedConversationHashesProvider?().contains(block.contentHash) != true
            else { return }
            self.conversationSuggestionIdentity = capturedIdentity
            self.conversationSuggestion = block
            self.conversationSuggestionDidChange?(block)
        }
    }

    /// Enter 승인 (요구사항 §20) — 기록을 실행하고 true. 호출부(에디터)는
    /// false를 리턴해 **개행도 정상 진행**시킨다 — 글쓰기 흐름이 끊기지 않는다.
    @discardableResult
    public func acceptConversationSuggestion() -> Bool {
        guard let block = conversationSuggestion,
            let onRecordConversation
        else { return false }
        if let provider = projectDocumentProvider,
            provider()?.identity == nil || provider()?.identity != conversationSuggestionIdentity {
            clearConversationSuggestion()
            return false
        }
        clearConversationSuggestion()
        // 기록 승인 = 사용자 결정 — 참여자 귀속·주제는 백그라운드가 보완한다.
        onRecordConversation(ConversationDetector.record(from: block, utterances: []))
        return true
    }

    /// 제안 닫기 — remember면 같은 내용을 다시 묻지 않는다 (Esc·계속 입력).
    public func dismissConversationSuggestion(remember: Bool) {
        if remember, let block = conversationSuggestion {
            dismissedConversationHashes.insert(block.contentHash)
        }
        conversationTask?.cancel()
        conversationTask = nil
        clearConversationSuggestion()
    }

    public var hasConversationSuggestion: Bool { conversationSuggestion != nil }

    private func clearConversationSuggestion() {
        conversationSuggestionIdentity = nil
        guard conversationSuggestion != nil else { return }
        conversationSuggestion = nil
        conversationSuggestionDidChange?(nil)
    }

    public let settings: CompletionSettings
    private let engine: CompletionEngine

    func makeWorkspaceAssistance(session: ProjectSession, requests: ProjectEditorRequests, margin: LivingMarginModel) -> WorkspaceAssistance {
        let model = WorkspaceAssistance(session: session, requests: requests, margin: margin) { [weak self] system, user in
            let process = ProcessInfo.processInfo
            guard let self, self.settings.authorization == .enabled, self.settings.autocompleteEnabled,
                  self.engineState == .ready, !self.isMemoryPressurePaused, !self.isManagingModel,
                  !self.foregroundIsBusy, !process.isLowPowerModeEnabled,
                  process.thermalState != .serious, process.thermalState != .critical else {
                throw CompletionEngine.ReadyInstructionError.modelUnavailable
            }
            let engine = self.engine, parameters = self.settings.parameters
            return AskAnswerGeneration { emit in
                try await engine.streamInstructionIfReady(system: system, user: user, parameters: parameters, onChunk: emit)
            }
        }
        model.observe(self)
        observeForegroundCompletion(owner: model) { [weak model] busy in if busy { model?.cancel() } }
        return model
    }

    private weak var currentJudgeSupport: ContinuityJudgeSupport?
    func makeContinuityJudgeSupport() -> ContinuityJudgeSupport {
        currentJudgeSupport?.shutdown()
        let support = ContinuityJudgeSupport(available: false) { [weak self] packet in
            let process = ProcessInfo.processInfo
            guard let self, self.settings.authorization == .enabled, self.settings.autocompleteEnabled, self.engineState == .ready,
                  !self.isMemoryPressurePaused, !self.isManagingModel, !process.isLowPowerModeEnabled,
                  process.thermalState != .serious, process.thermalState != .critical else { throw CompletionEngine.ReadyInstructionError.modelUnavailable }
            let engine = self.engine, parameters = self.settings.parameters, user = try packet.userMessage()
            return AskAnswerGeneration { emit in
                try await engine.streamInstructionIfReady(system: JudgeEvidencePacket.systemMessage, user: user, parameters: parameters, onChunk: emit)
            }
        }
        currentJudgeSupport = support; support.observe(self); return support
    }

    func makeAskPurlorySupport() -> AskPurlorySupport {
        let support = AskPurlorySupport(available: false) { [weak self] packet, question in
            guard let self, self.settings.authorization == .enabled, self.settings.autocompleteEnabled, self.engineState == .ready,
                  !self.isMemoryPressurePaused, !self.isManagingModel else { throw CompletionEngine.ReadyInstructionError.modelUnavailable }
            return try AskAnswerGeneration.local(engine: self.engine, packet: packet, question: question, parameters: self.settings.parameters)
        }
        support.observe(self); return support
    }

    /// 앱 수명 동안의 컨트롤러 — 종료 훅(AppDelegate)이 접근하려고 둔다.
    /// EntryStore.current와 같은 패턴. 테스트가 여러 인스턴스를 만들면 마지막이
    /// 이기지만, current를 쓰는 곳은 앱 종료뿐이라 무해하다.
    public private(set) weak static var current: CompletionController?

    /// 활성 문서 스냅샷 공급자 — ContentView가 1회 배선한다. 예측 직전에 pull해
    /// 제목·장르·인물 카드를 조립기에 넘긴다 (PLAN §10). 푸시(onChange) 대신
    /// pull인 이유: 본문이 큰 저널에서 매 키 입력마다 Equatable 비교를 하지 않는다.
    public var documentContextProvider: (() -> DocumentContext?)?
    public var projectDocumentProvider: (() -> ProjectDocumentSnapshot?)?
    private var writerReader = WriterDocumentReader()

    func currentDocumentContext() -> DocumentContext? {
        if let projectDocumentProvider {
            guard let snapshot = projectDocumentProvider(),
                let writer = try? writerReader.read(snapshot) else { return nil }
            return DocumentContext(
                title: snapshot.title, kind: snapshot.mode == .fiction ? .novel : .journal,
                genre: writer.genre, characters: writer.characters,
                entryID: snapshot.identity.key.documentID.rawValue)
        }
        return documentContextProvider?()
    }

    /// 지식 스냅샷 공급자 (M6, PLAN §11) — 인덱서가 발행한 인메모리 값만 pull.
    /// 활성 문서와의 일치 확인은 배선부(ContentView)의 몫이다.
    public var knowledgeProvider: (() -> KnowledgeSnapshot?)?
    public var originalNameAnchorsProvider: (() -> OriginalNameAnchorIndex?)?
    public var contextConfigurationDidChange: (() -> Void)?
    public var foregroundCompletionDidChange: ((Bool) -> Void)?
    private final class ForegroundObserver {
        weak var owner: AnyObject?
        let handler: (Bool) -> Void
        init(owner: AnyObject, handler: @escaping (Bool) -> Void) { self.owner = owner; self.handler = handler }
    }
    private var foregroundObservers: [ObjectIdentifier: ForegroundObserver] = [:]
    private var foregroundIsBusy = false
    func observeForegroundCompletion(owner: AnyObject, handler: @escaping (Bool) -> Void) {
        foregroundObservers = foregroundObservers.filter { $0.value.owner != nil }
        foregroundObservers[ObjectIdentifier(owner)] = ForegroundObserver(owner: owner, handler: handler)
        handler(foregroundIsBusy)
    }
    private func notifyForegroundCompletion(_ busy: Bool) {
        foregroundIsBusy = busy
        foregroundCompletionDidChange?(busy)
        foregroundObservers = foregroundObservers.filter { $0.value.owner != nil }
        for observer in Array(foregroundObservers.values) { observer.handler(busy) }
    }
    public var usesOriginalNameAnchors: Bool {
        !isMemoryPressurePaused && settings.authorization == .enabled && settings.autocompleteEnabled
            && settings.ghostContextMode == .rawWithNameAnchor
    }

    /// 종류별 컨텍스트 창 상한 — 소설은 넓게 (PLAN §10 Smart/Story 예산).
    /// 에디터(BlockTextView)가 prefix 추출 한도로 읽는다.
    public var effectiveContextCharacters: Int {
        let current = currentDocumentContext()?.kind == .novel
            ? settings.novelContextCharacters
            : settings.contextCharacters
        guard settings.ghostContextMode != .current, cachedCounter != nil,
            cachedCounterModelID == settings.modelID else { return current }
        return min(12_000, max(current, 8_000))
    }
    private var pendingTask: Task<Void, Never>?
    /// 편집/커서 이벤트마다 증가 — 뒤늦게 도착한 stale 응답을 버리는 기준.
    private var generation = 0
    /// 제안이 발행된 시점의 커서(UTF-16). 커서가 여기서 벗어나면 폐기.
    private var suggestionAnchor: Int?
    /// 대기 중 요청이 예약된 시점의 커서 — 생성 완료 전에 커서가 움직이면 취소.
    private var pendingCaret: Int?
    /// 로드에 실패한 모델 id — 같은 모델로의 재시도 폭주만 막고,
    /// 사용자가 Settings에서 모델을 바꾸면 다시 트리거를 허용한다.
    private var failedModelID: String?
    /// `→` 한 단어 수락 직후의 편집 이벤트에서 남은 고스트를 지우지 않기 위한 플래그.
    private var retainSuggestionOnNextEdit = false
    /// 마지막으로 본 커서 위치 (UTF-16) — 인덱서의 **커서 거리순 순회**용
    /// (docs/m6-scene-split.md §5: 씬이 수십 개면 쓰고 있는 장부터 이해해야
    /// 한다). Int 하나 저장 — 키 입력 경로 비용 없음.
    public private(set) var lastCaretLocation: Int?
    /// 현재 고스트가 만들어진 모드 (fast/smart/story[-dialogue]) — 수락률
    /// 로그의 축 (M7, PLAN §13). 제안과 함께 세팅·소멸한다.
    private var currentSuggestionMode: String?
    private var currentOpportunity: AcceptanceMetrics.Opportunity?
    private let metricsStorageLocation: PurloryStorageLocation
    /// 수락이 곧 invalidate를 부르므로, 그 invalidate가 "거절"로 기록되지
    /// 않게 하는 1회용 플래그.
    private var suppressDismissLog = false

    // MARK: - 입력 지연 계측 (로컬 전용 진단 — PLAN §13 온라인 지표)

    /// 최근 키 입력 처리 시간 통계 — 상태 바가 표시한다. **원격 전송 절대 금지.**
    /// 랙 보고를 "느려요"가 아니라 숫자로 만들기 위한 장비: 핸들러(우리 코드)와
    /// 총 시간(렌더 포함)을 나눠 재므로, 랙의 소재가 어느 쪽인지 갈린다.
    public struct KeystrokeStats: Equatable, Sendable {
        /// 에디터 핸들러(직렬화·저장 전달)만의 p95 (ms).
        public var handlerP95: Double = 0
        /// 키 입력 → 메인 스레드가 한가해질 때까지 (SwiftUI 갱신·레이아웃 포함) p95.
        public var totalP95: Double = 0
        /// 최근 표본 중 최대 총 시간 (ms) — 간헐 스파이크 포착용.
        public var totalMax: Double = 0
        public var samples: Int = 0
    }

    @Published public private(set) var keystrokeStats = KeystrokeStats()
    private var handlerSamples: [Double] = []
    private var totalSamples: [Double] = []

    /// 에디터가 키 입력 하나를 처리할 때마다 호출 (BlockTextView Coordinator).
    /// 발행은 20표본마다 — 계측이 제 관찰 비용을 만들지 않게 한다.
    public func noteKeystroke(handlerMs: Double, totalMs: Double) {
        handlerSamples.append(handlerMs)
        totalSamples.append(totalMs)
        if handlerSamples.count > 120 {
            handlerSamples.removeFirst(handlerSamples.count - 120)
            totalSamples.removeFirst(totalSamples.count - 120)
        }
        guard totalSamples.count % 20 == 0 else { return }
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        keystrokeStats = KeystrokeStats(
            handlerP95: p95(handlerSamples),
            totalP95: p95(totalSamples),
            totalMax: totalSamples.max() ?? 0,
            samples: totalSamples.count)
    }

    public init(
        settings: CompletionSettings = .shared,
        engine: CompletionEngine = CompletionEngine(),
        metricsStorageLocation: PurloryStorageLocation = .standard
    ) {
        self.settings = settings
        self.engine = engine
        self.metricsStorageLocation = metricsStorageLocation
        Self.current = self
    }

    @Published public private(set) var isManagingModel = false
    @Published public private(set) var modelOperationError: String?
    private var preloadToken: UUID?
    @Published public private(set) var isMemoryPressurePaused = false
    public static let memoryPressureMessage = "메모리가 부족해 자동완성을 쉬고 있어요. 원고 편집은 계속할 수 있습니다. 여유가 생기면 다시 시도해 주세요."
    private var pressurePriorFailure: (state: EngineState, modelID: String)?

    /// Temporary admission only: do not change durable AI consent or model selection.
    /// The pressure coordinator keeps this closed until the engine unload drains.
    public func setMemoryPressurePaused(_ paused: Bool) {
        guard isMemoryPressurePaused != paused else { return }
        isMemoryPressurePaused = paused
        if paused {
            if case .failed = engineState, let modelID = failedModelID {
                pressurePriorFailure = (engineState, modelID)
            } else { pressurePriorFailure = nil }
            preloadToken = nil
            preloadTask?.cancel(); preloadTask = nil
            shutdown()
            conversationTask?.cancel(); conversationTask = nil
            lastContextReport = nil
            cachedCounter = nil; cachedCounterModelID = nil
            engineState = .failed(Self.memoryPressureMessage)
        } else {
            if let prior = pressurePriorFailure, prior.modelID == settings.modelID {
                engineState = prior.state; failedModelID = prior.modelID
            } else { engineState = .idle; failedModelID = nil }
            pressurePriorFailure = nil
        }
        contextConfigurationDidChange?()
    }

    public func noteMemoryReleaseFailure(_ error: Error) {
        modelOperationError = error.localizedDescription
    }

    public func removeModel(_ id: String, store: ModelInstallationStore = .shared) async throws {
        guard !isMemoryPressurePaused, !isManagingModel else { throw ModelInstallError.busy }
        isManagingModel = true; modelOperationError = nil
        defer { isManagingModel = false }
        let active = settings.modelID == id, resume = settings.autocompleteEnabled
        do {
            try await suspendModelWork()
            await ModelDownloadManager.shared.cancelAndWait(id)
            try await store.remove(id)
            if active { settings.modelID = "" }
            isManagingModel = false
            if !active, resume { setAutocompleteEnabled(true) }
        } catch { modelOperationError = error.localizedDescription; throw error }
    }
    public func replaceModel(with id: String) async throws {
        guard let manifest = PinnedModelCatalog.manifest(for: id) else { throw ModelInstallError.metadata }
        try ModelMemoryPolicy.current.requireLoad(manifest: manifest)
        try await replaceModel(manifest: manifest, store: .shared, download: ModelDownloadManager.transfer)
    }
    /// The public entry point validates release policy before this owned-install handoff.
    func replaceModel(manifest: ModelInstallManifest, store: ModelInstallationStore, download: @escaping ModelInstallationStore.Download) async throws {
        guard !isMemoryPressurePaused, !isManagingModel else { throw ModelInstallError.busy }
        isManagingModel = true; modelOperationError = nil
        defer { isManagingModel = false }
        let previous = settings.modelID, resume = settings.autocompleteEnabled
        do {
            try await suspendModelWork()
            await ModelDownloadManager.shared.cancelAndWait(previous)
            if previous.isEmpty { _ = try await store.install(manifest, download: download) }
            else { _ = try await store.replace(previous, with: manifest, download: download) }
            settings.modelID = manifest.id
            isManagingModel = false
            if resume { setAutocompleteEnabled(true) }
        } catch { modelOperationError = error.localizedDescription; throw error }
    }
    private func suspendModelWork() async throws {
        let previous = preloadTask
        preloadToken = nil; previous?.cancel(); preloadTask = nil
        setAutocompleteEnabled(false)
        shutdown(); lastContextReport = nil
        cachedCounter = nil; cachedCounterModelID = nil; failedModelID = nil; engineState = .idle
        if let previous { await previous.value }
        try await engine.unload()
    }

    // MARK: - 엔진 로드

    /// 앱 시작 시 모델을 미리 로드해 모델 상주(PLAN §9-2)로 첫 제안 지연을 지킨다.
    /// 설정에서 자동완성을 명시적으로 허용한 뒤에만 모델을 로드한다.
    public func preloadEngine() {
        guard !isMemoryPressurePaused, !isManagingModel, settings.authorization == .enabled, settings.autocompleteEnabled else { return }
        switch engineState {
        case .idle, .failed: break
        default: return
        }
        engineState = .downloading(0)
        let parameters = settings.parameters, token = UUID()
        preloadToken = token
        // 진행률 coalescing — 허브 로더는 초당 수십 번 부르지만 UI 갱신은
        // 250ms면 충분하다. 틱마다 MainActor 태스크를 스폰하던 낭비 제거 (이슈 #46).
        let throttle = ProgressCoalescer()
        // 로드 태스크를 보관한다 — 스위치를 끄면 수 GB 네트워크가 혼자 도는
        // 일을 끊는 유일한 손잡이다 (이슈 #46). 이전 로드가 살아 있으면 먼저 접는다.
        preloadTask?.cancel()
        let task = Task { [engine] in
            do {
                try await engine.preload(parameters: parameters) { fraction in
                    guard throttle.shouldEmit(fraction) else { return }
                    Task { @MainActor [weak self] in
                        self?.noteLoadProgress(fraction, modelID: parameters.modelID, token: token)
                    }
                }
                guard self.preloadToken == token, !Task.isCancelled, !self.isManagingModel,
                      self.settings.autocompleteEnabled, self.settings.modelID == parameters.modelID else { return }
                self.markEngineReady()
            } catch is CancellationError {
                // 모델 교체·스위치 OFF로 이 로드가 취소됨 — 상태는 요청자가 정리한다.
            } catch {
                guard self.preloadToken == token, !self.isManagingModel, self.settings.autocompleteEnabled else { return }
                self.markEngineFailed(error, modelID: parameters.modelID)
            }
        }
        preloadTask = task
    }

    /// 로드 실패 후 재시도 (모델 id를 바꾼 뒤 등).
    public func retryEngineLoad() {
        guard !isMemoryPressurePaused else { return }
        engineState = .idle
        failedModelID = nil
        preloadEngine()
    }

    /// 모델 스위처에서 모델을 바꿨다 — 고스트 폐기 후 새 모델을 즉시 로드.
    /// 인스펙터 리포트도 함께 폐기한다 — 이전 모델이 참고한 맥락이 새 모델
    /// 상태 표시 옆에 남으면 사용자를 오도한다 (이슈 #11).
    public func modelDidChange() {
        guard !isMemoryPressurePaused else { return }
        guard !isManagingModel else { return }
        preloadToken = nil
        invalidate()
        lastContextReport = nil
        engineState = .idle
        failedModelID = nil
        preloadEngine()
    }

    /// 모델 변경 의도 (이슈 #11) — 설정 값과 무효화를 한 번에. 설정 창·툴바가
    /// settings.modelID를 직접 고치면 이 무효화를 우회해 이전 모델 결과가
    /// 나타날 수 있었다. 같은 id면 아무 일도 일어나지 않는다.
    public func changeModel(to id: String) {
        guard !isManagingModel, id != settings.modelID else { return }
        settings.modelID = id
        modelDidChange()
    }

    public func changeContextMode(to mode: GhostContextMode) {
        guard mode != settings.ghostContextMode else { return }
        invalidate()
        lastContextReport = nil
        settings.ghostContextMode = mode
        contextConfigurationDidChange?()
    }

    /// 자동완성 마스터 스위치 토글. 이 사용자 조작이 명시적 허용 상태를 기록한다.
    /// 끄면 진행 중인 제안까지 즉시 폐기하고, 켜면 모델을 로드한다.
    public func setAutocompleteEnabled(_ enabled: Bool) {
        guard !enabled || !isManagingModel else { return }
        let authorization: CompletionAuthorization = enabled ? .enabled : .disabled
        guard settings.authorization != authorization
            || settings.autocompleteEnabled != enabled
        else { return }
        settings.setCompletionEnabled(enabled)
        contextConfigurationDidChange?()
        if enabled {
            preloadEngine()
        } else {
            invalidate()
            // 진행 중 모델 로드(다운로드)도 함께 접는다 — 이게 없으면 OFF 후에도
            // 수 GB 전송이 계속된다 (이슈 #46).
            preloadToken = nil
            preloadTask?.cancel()
            preloadTask = nil
            if !isMemoryPressurePaused { engineState = .idle }
            // 꺼진 순간 마지막 리포트도 과거의 것이다 — 남겨두면 꺼져 있는데
            // 컨텍스트 화면이 살아 있는 모순이 생긴다 (이슈 #11).
            lastContextReport = nil
            // 이름 생성도 접는다 — 스위치가 꺼진 뒤엔 이 이름이 도착해도 어긋난다.
            cancelAllFolderNaming()
        }
    }

    func noteLoadProgress(_ fraction: Double, modelID: String, token: UUID? = nil, expectedGeneration: Int? = nil) {
        guard !isMemoryPressurePaused, !isManagingModel, settings.autocompleteEnabled, settings.modelID == modelID,
              token == nil || token == preloadToken,
              expectedGeneration == nil || expectedGeneration == generation else { return }
        switch engineState {
        case .ready: return
        default: engineState = fraction >= 1 ? .loading : .downloading(fraction)
        }
    }

    private func markEngineReady() {
        engineState = .ready
        failedModelID = nil
        // A pinned model's tokenizer stays valid across completed requests. Only a
        // different selected model invalidates its cached budget/window eligibility.
        if cachedCounterModelID != settings.modelID {
            cachedCounter = nil
            cachedCounterModelID = nil
        }
    }

    /// Reuse the selected loaded tokenizer; retry a missing snapshot after load.
    private var cachedCounter: TokenCounter?
    private var cachedCounterModelID: String?

    private func tokenCounter(for modelID: String) async -> TokenCounter? {
        if cachedCounterModelID == modelID, let cachedCounter { return cachedCounter }
        let counter = await engine.makeTokenCounter(expectedModelID: modelID)
        rememberTokenCounter(counter, for: modelID)
        return counter
    }
    func rememberTokenCounter(_ counter: TokenCounter?, for modelID: String) {
        guard !isMemoryPressurePaused, modelID == settings.modelID else { return }
        cachedCounter = counter
        cachedCounterModelID = modelID
    }

    private func markEngineFailed(_ error: Error, modelID: String) {
        // 그 사이 다른 모델로 바뀌었다면 이 실패는 이미 낡은 정보다.
        guard settings.modelID == modelID else { return }
        engineState = .failed(error.localizedDescription)
        failedModelID = modelID
        // 콜드 로드 실패 = 이름 생성이 영영 끝나지 못함 — 스피너를 풀어준다
        // (이슈 #47의 "스피너 무한 회전" 본경로).
        cancelAllFolderNaming()
    }

    // MARK: - 에디터 이벤트

    /// 텍스트가 변했다 — 기존 고스트/작업 폐기 후, 게이트를 통과하면 새 제안 예약.
    public func noteEdit(
        prefix: String,
        caretLocation: Int,
        isComposing: Bool,
        caretAtParagraphEnd: Bool
    ) {
        lastCaretLocation = caretLocation
        // `→` 한 단어 수락이 만든 편집 — 남은 고스트를 유지하고 새 요청도 걸지 않는다.
        if retainSuggestionOnNextEdit {
            retainSuggestionOnNextEdit = false
            if suggestion != nil {
                suggestionAnchor = caretLocation
                return
            }
            // 제안을 다 소진했다 — 아래 일반 경로로 다음 제안을 예약한다.
        }

        invalidate()  // 편집 즉시 고스트 제거 + in-flight 취소 (PLAN §5)

        // 대화 기록 제안 — 입력이 이어지면 닫고(같은 내용 재질문 금지), 유휴 뒤
        // 다시 감지한다 (요구사항 §20 "일반 문자 입력: 제안을 닫고 정상 입력 계속").
        // 결정적·LLM 없음이라 자동완성 마스터 스위치와 무관하다.
        if conversationSuggestion != nil { dismissConversationSuggestion(remember: true) }
        if !isComposing, !isMemoryPressurePaused {
            scheduleConversationDetection(prefix: prefix, caretLocation: caretLocation)
        }

        guard !isMemoryPressurePaused, settings.authorization == .enabled,
            settings.autocompleteEnabled
        else { return }  // 명시적 허용 전이거나 마스터 스위치 꺼짐
        guard !isComposing else { return }  // 한글 IME 조합 중 — 트리거 금지 (PLAN §2)
        guard caretAtParagraphEnd else { return }
        // 같은 모델로 실패했으면 재시도 폭주 방지. 모델을 바꿨으면 다시 허용.
        if case .failed = engineState, settings.modelID == failedModelID { return }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }  // 컨텍스트가 너무 빈약하면 스킵

        let expected = generation
        let parameters = settings.parameters
        let debounce = Duration.milliseconds(settings.debounceMilliseconds)

        pendingCaret = caretLocation
        pendingTask = Task { [weak self] in
            // 입력이 멈출 때까지 대기 — 그 사이 새 입력이 오면 이 태스크가 취소된다.
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            // "예측 중" 표시는 디바운스가 끝난 실제 생성 개시에만 켠다 —
            // 타이핑 중 ModelChip 애니메이션이 진동하지 않게 (이슈 #51).
            if !self.isPredicting { self.isPredicting = true }
            await self.runCompletion(
                prefix: prefix,
                caretLocation: caretLocation,
                parameters: parameters,
                expected: expected
            )
        }
    }

    /// 커서/선택이 움직였다 — 제안(또는 대기 중 요청)의 위치를 벗어나면 폐기.
    ///
    /// 타이핑도 커서를 움직이지만, 그 경우 `noteEdit`가 같은 커서 위치로
    /// 재예약하므로(위치 일치 → no-op) 알림 순서와 무관하게 안전하다.
    public func noteSelectionChange(caretLocation: Int) {
        lastCaretLocation = caretLocation
        if suggestion != nil {
            if suggestionAnchor != caretLocation { invalidate() }
        } else if pendingTask != nil {
            if pendingCaret != caretLocation { invalidate() }
        }
        // 대화 제안 — 커서가 블록을 떠나면 조용히 닫는다 (기억하지 않는다:
        // 돌아와 이어 쓰면 다시 제안될 수 있다).
        if let block = conversationSuggestion,
            caretLocation < block.utf16Range.lowerBound
                || caretLocation > block.utf16Range.upperBound + 2
        {
            dismissConversationSuggestion(remember: false)
        }
    }

    // MARK: - 수락 / 거부

    public var hasSuggestion: Bool { suggestion != nil }

    /// `Tab` 수락 — 뷰가 본문에 삽입할 텍스트를 반환. 제안이 없으면 nil.
    public func acceptSuggestion() -> String? {
        guard let text = suggestion, !text.isEmpty else { return nil }
        logSuggestion(.acceptedFull)
        suppressDismissLog = true
        invalidate()
        return text
    }

    /// `→` 한 단어 수락 (에디터 v3) — 제안의 선행 공백+첫 어절만 반환하고,
    /// 나머지는 고스트로 남긴다. 뷰는 반환값을 본문에 삽입한다.
    ///
    /// `insertionLocation`은 삽입 직전 커서(UTF-16). 삽입이 만들 편집·커서
    /// 이벤트에서 남은 고스트가 폐기되지 않도록 앵커를 미리 옮겨 둔다.
    public func acceptWord(insertionLocation: Int) -> String? {
        guard let text = suggestion, !text.isEmpty else { return nil }
        var rest = Substring(text)
        var word = ""
        while let first = rest.first, first.isWhitespace {
            word.append(first)
            rest = rest.dropFirst()
        }
        while let first = rest.first, !first.isWhitespace {
            word.append(first)
            rest = rest.dropFirst()
        }
        guard !word.isEmpty else { return nil }
        logSuggestion(.acceptedWord)

        let remainder = String(rest)
        retainSuggestionOnNextEdit = true
        suggestionAnchor = insertionLocation + (word as NSString).length
        suggestion = remainder.isEmpty ? nil : remainder
        suggestionDidChange?(suggestion)
        return word
    }

    /// `Esc`·포커스 이탈·외부 텍스트 교체 — 고스트 폐기 + in-flight 취소.
    public func dismissSuggestion() {
        invalidate()
    }

    // MARK: - 폴더 이름 생성 (사이드바 DnD)

    /// AI 이름 생성이 진행 중인 폴더들 — 사이드바 행의 로딩 점 표시용.
    @Published public private(set) var namingFolderIDs: Set<UUID> = []

    /// 모델 로드(다운로드 포함) 태스크 — 마스터 스위치 OFF 때 접는 손잡이.
    /// 보관하지 않으면 수 GB 네트워크 전송이 끝까지 혼자 돈다 (이슈 #46).
    private var preloadTask: Task<Void, Never>?

    /// 폴더별 이름 생성 태스크 (이슈 #47). 미추적이면 콜드 모델 로드 수 분 동안
    /// 스피너가 도는 걸 끊을 방법이 없었다. 취소는 소유자(아래 cancel 계열)만
    /// 딕셔너리를 정리하고, 태스크는 깨어나 `Task.isCancelled`로 스스로 물러난다 —
    /// 늦게 풀린 옛 태스크가 새 요청의 표시·딕셔너리를 침범하지 않게.
    private var folderNamingTasks: [UUID: Task<Void, Never>] = [:]

    /// 자동 생성 폴더("새 폴더")의 이름을 멤버 문서 내용에서 지어 붙인다.
    ///
    /// 엔진을 쓸 수 없으면(자동완성 꺼짐·로드 실패) 조용히 기본 이름을 유지한다 —
    /// 폴더 명명이 대용량 모델 다운로드를 유발해서는 안 된다. 실패·빈 결과도
    /// 같은 폴백. 고스트 자동완성의 generation/suggestion에는 손대지 않으므로
    /// 타이핑 중 제안 흐름과 간섭하지 않는다 (엔진 actor가 순차 처리).
    public func requestFolderName(for folderID: UUID, in store: EntryStore) {
        guard !isMemoryPressurePaused, settings.authorization == .enabled, settings.autocompleteEnabled else { return }
        if case .failed = engineState { return }
        guard !namingFolderIDs.contains(folderID) else { return }
        let content = store.folderNamingContext(
            for: folderID, maxCharacters: settings.contextCharacters)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        namingFolderIDs.insert(folderID)
        let parameters = settings.parameters
        // 이름이 도착할 때까지 self를 붙잡는다(수명 유한) — 진행 표시 해제가 목적.
        let task = Task { [engine, weak store] in
            let name =
                (try? await engine.generateFolderName(
                    content: content, parameters: parameters)) ?? ""
            // 취소됐다면 정리는 이미 취소 경로가 끝냈고 이름도 적용하지 않는다
            // (stale 결과 무시, 이슈 #47). 여기서 건드리지 않는 이유 — 이 태스크가
            // 풀리기 전에 같은 폴더에 새 요청이 들어왔을 수 있다.
            guard !Task.isCancelled else { return }
            self.folderNamingTasks[folderID] = nil
            self.namingFolderIDs.remove(folderID)
            guard !name.isEmpty, let store else { return }
            // 사용자가 그 사이 직접 이름을 바꿨다면 스토어 쪽 가드가 조용히 무시한다.
            // 모션 정책 (#27): Reduce Motion이면 즉시 반영. 저빈도(폴더당 1회)
            // 이지만 시스템 설정을 존중하는 게 규약이다.
            let namingAnimation: Animation? =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil : .easeOut(duration: 0.18)
            withAnimation(namingAnimation) {
                store.renameFolderIfPlaceholder(folderID, to: name)
            }
        }
        folderNamingTasks[folderID] = task
    }

    /// 프로젝트 탐색기에서 문서를 합쳐 만든 자동 생성 폴더("새 폴더")의 이름을
    /// 로컬 엔진이 준비된 경우에만 조용히 지어 붙인다.
    public func requestFolderName(for folderID: UUID, in session: ProjectSession) {
        guard !isMemoryPressurePaused, settings.authorization == .enabled, settings.autocompleteEnabled,
              engineState == .ready, !isManagingModel, !foregroundIsBusy,
              let project = session.activeProject,
              let navigation = try? ProjectNavigation.read(project) else { return }
        guard !namingFolderIDs.contains(folderID) else { return }
        let members = project.documents.filter {
            !project.trashedDocumentIDs.contains($0.id) && navigation.documentFolders[$0.id] == folderID
        }
        guard !members.isEmpty else { return }
        let content = String(members.enumerated().map { index, doc in
            "[문서 \(index + 1)] 제목: \(doc.title)\n\(doc.body.prefix(300))"
        }.joined(separator: "\n\n").prefix(settings.contextCharacters))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let projectID = project.id
        let epoch = session.activationEpoch
        namingFolderIDs.insert(folderID)
        let parameters = settings.parameters
        let task = Task { [engine, weak session] in
            let name = (try? await engine.generateFolderName(content: content, parameters: parameters)) ?? ""
            guard !Task.isCancelled else { return }
            self.folderNamingTasks[folderID] = nil
            self.namingFolderIDs.remove(folderID)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let session,
                  session.activeProject?.id == projectID,
                  session.activationEpoch == epoch,
                  let currentProject = session.activeProject,
                  let currentNav = try? ProjectNavigation.read(currentProject),
                  let folder = currentNav.folders.first(where: { $0.id == folderID }),
                  folder.name == "새 폴더" else { return }
            let namingAnimation: Animation? =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil : .easeOut(duration: 0.18)
            withAnimation(namingAnimation) {
                try? session.applyNavigation(.renameFolder(folderID, trimmed), projectID: projectID, epoch: epoch)
            }
        }
        folderNamingTasks[folderID] = task
    }

    /// 테스트 전용 — 실제 엔진 호출 없이 진행 상태와 장수 태스크를 심어
    /// 취소 경로(스피너 즉시 해제)를 검증한다 (이슈 #47).
    @discardableResult
    func _testInjectNamingTask(folderID: UUID) -> Task<Void, Never> {
        namingFolderIDs.insert(folderID)
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        folderNamingTasks[folderID] = task
        return task
    }

    /// 사이드바 행이 사라졌다(삭제·접힘·필터) — 그 폴더의 이름 생성을 접는다.
    /// 보이지 않는 스피너를 위해 수 분 생성을 돌려두는 일이 없게 (이슈 #47).
    public func cancelFolderName(for folderID: UUID) {
        folderNamingTasks.removeValue(forKey: folderID)?.cancel()
        namingFolderIDs.remove(folderID)
    }

    /// 이름 생성 전부 중단 — 자동완성 종료·모델 로드 실패처럼 이 이름이 더는
    /// 도착할 수 없는 터미널 상태에서 부른다. 고스트 invalidate()와는 달리
    /// 편집마다 부르지 않는다 — 명명은 타이핑과 간섭 없이 완료되기로 되어 있다.
    private func cancelAllFolderNaming() {
        for (_, task) in folderNamingTasks { task.cancel() }
        folderNamingTasks.removeAll()
        guard !namingFolderIDs.isEmpty else { return }
        namingFolderIDs.removeAll()
    }

    // MARK: - 내부

    /// 앱 종료 직전 호출 — 예측·폴더 명명 태스크를 접어, 엔진의 드레인 대기가
    /// 길어지지 않게 한다 (이슈 #65 Gate 0 teardown 세그폴트 수정). 고스트 UI
    /// 정리도 겸하지만 종료 직후라 화면은 신경 쓰지 않는다.
    public func shutdown() {
        currentJudgeSupport?.shutdown()
        invalidate()
        cancelAllFolderNaming()
    }

    private func invalidate(preservingSuggestion: Bool = false) {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        notifyForegroundCompletion(false)
        pendingCaret = nil
        if isPredicting { isPredicting = false }
        guard !preservingSuggestion else { return }
        suggestionAnchor = nil
        if suggestion != nil {
            // 수락 경로가 아니면 이 소멸은 거절이다 (편집·Esc·커서 이동).
            if !suppressDismissLog {
                logSuggestion(.dismissed)
            }
            suggestion = nil
            suggestionDidChange?(nil)
        }
        suppressDismissLog = false
        currentSuggestionMode = nil
        currentOpportunity = nil
    }

    private func runCompletion(
        prefix: String,
        caretLocation: Int,
        parameters: CompletionParameters,
        expected: Int
    ) async {
        // 이 요청이 아직 최신일 때만 "예측 중"을 끈다 — 낡았다면 새 요청이 관리한다.
        notifyForegroundCompletion(true)
        defer {
            if expected == generation {
                if isPredicting { isPredicting = false }
                notifyForegroundCompletion(false)
            }
        }
        // 조립은 예측 시점의 마지막 MainActor 작업 — 준비된 값(메타·카드·요약)을
        // 얹기만 하고, 지식 계산은 전부 백그라운드의 몫이다 (CLAUDE.md §2-2).
        let capturedIdentity = projectDocumentProvider?()?.identity
        let document = currentDocumentContext()
        let knowledge = knowledgeProvider?()
        let originalNameAnchors = parameters.ghostContextMode == .rawWithNameAnchor
            ? originalNameAnchorsProvider?() : nil
        // 토큰 카운터 (#43) — 로드된 모델이 있으면 예산을 토큰으로 접고, 없으면
        // 조립기가 현행 문자 상수를 쓴다 (동작 불변).
        let counter = await tokenCounter(for: parameters.modelID)
        guard expected == generation,
            capturedIdentity == projectDocumentProvider?()?.identity,
            !Task.isCancelled
        else { return }
        var (prompt, report) = ContextAssembler.assembleWithReport(
            prefix: prefix,
            document: document,
            knowledge: knowledge,
            // C 창이 본문 어디서 시작하는지 — 이 앞에서 끝난 씬만 B로 들어간다.
            prefixStartUTF16: max(0, caretLocation - (prefix as NSString).length),
            style: parameters.promptStyle,
            tokenCounter: counter,
            tokenBudget: parameters.maxPromptTokens,
            contextMode: parameters.ghostContextMode,
            originalNameAnchors: originalNameAnchors
        )
        // 인스펙터 갱신 — 이 요청이 실제로 쓰는 컨텍스트다 (생성 성패와 무관:
        // 무엇이 주입됐는지가 관심사다). 소속 문서·세대를 찍어 다른 작품 화면에서
        // 보여지거나 그 오버라이드에 기록되는 일을 막는다 (이슈 #8).
        report.entryID = document?.entryID
        report.generation = expected
        report.runtimeIdentity = capturedIdentity
        lastContextReport = report
        // 대화 모드 (PLAN §10) — 커서가 열린 따옴표 안이면 정지 사다리를 발화
        // 끝으로 확장한다. 조립기의 말투 승격과 같은 감지를 써서 어긋나지 않는다.
        var parameters = parameters
        if document?.kind == .novel, ContextAssembler.isInsideUtterance(prefix) {
            parameters.stopAtUtteranceEnd = true
        }
        // 수락률 로그의 모드 축 (M7, PLAN §13·§10 모드 표).
        let mode: String = {
            guard document?.kind == .novel else { return "fast" }
            let base = knowledge != nil ? "story" : "smart"
            return parameters.stopAtUtteranceEnd ? base + "-dialogue" : base
        }()
        let requestModelID = parameters.modelID
        do {
            let completion = try await engine.complete(prompt: prompt, parameters: parameters) {
                fraction in
                Task { @MainActor [weak self] in
                    self?.noteLoadProgress(fraction, modelID: requestModelID, expectedGeneration: expected)
                }
            }
            guard expected == generation,
                capturedIdentity == projectDocumentProvider?()?.identity
            else { return }
            publishCompletion(completion, caretLocation: caretLocation, mode: mode,
                contextMode: parameters.ghostContextMode, modelID: parameters.modelID)
        } catch is CancellationError {
            // 새 입력으로 취소됨 — 정상 흐름.
        } catch {
            guard expected == generation,
                capturedIdentity == projectDocumentProvider?()?.identity
            else { return }
            markEngineFailed(error, modelID: parameters.modelID)
        }
    }

    /// Commit an owned engine result to the editor's acceptance lifecycle.
    func publishCompletion(
        _ completion: CompletionEngine.Completion, caretLocation: Int, mode: String,
        contextMode: GhostContextMode = .current, modelID: String? = nil
    ) {
        guard !isMemoryPressurePaused else { return }
        markEngineReady()
        lastLatency = completion.totalTime
        guard !completion.text.isEmpty else { return }
        suggestion = completion.text
        suggestionAnchor = caretLocation
        currentSuggestionMode = mode
        currentOpportunity = AcceptanceMetrics.Opportunity(mode: mode, contextMode: contextMode,
            latencyMs: Int(completion.totalTime * 1000),
            firstChunkMs: completion.timeToFirstChunk.map { Int($0 * 1000) }, modelID: modelID)
        logSuggestion(.shown)
        suggestionDidChange?(completion.text)
    }
    private func logSuggestion(_ event: AcceptanceMetrics.Event) {
        if let currentOpportunity {
            AcceptanceMetrics.log(event, opportunity: currentOpportunity, storageLocation: metricsStorageLocation)
        } else {
            AcceptanceMetrics.log(event, mode: currentSuggestionMode ?? "?", storageLocation: metricsStorageLocation)
        }
    }
}
