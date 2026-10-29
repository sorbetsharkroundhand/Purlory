import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Joins the MLX producer before releasing its cache or model container,
/// including paths that stop consuming text at a sentence boundary.
struct GenerationTaskSynchronizer: Sendable {
    let task: Task<Void, Never>

    func cancelAndWait() async {
        task.cancel()
        await task.value
    }

    func cancelAndCollectInfo(from iterator: inout AsyncStream<Generation>.Iterator) async -> GenerateCompletionInfo? {
        await cancelAndWait()
        // The producer is finished: only buffered events remain. Ignore text
        // beyond the consumer's boundary, but retain the final timing evidence.
        var info: GenerateCompletionInfo?
        while let generation = await iterator.next() {
            if case .info(let finalInfo) = generation { info = finalInfo }
        }
        return info
    }
}

extension GenerateCompletionInfo {
    var benchmarkTimeToFirstToken: TimeInterval? {
        // MLX promptTime includes prefill and the first sampled token, before
        // detokenization. An EOS-only or cancelled-before-token run is missing.
        guard generationTokenCount > 0, promptTime.isFinite, promptTime >= 0 else { return nil }
        return promptTime
    }
}

/// 모델 컨테이너 사용권과 교체권을 조정한다. 교체가 시작되면 새 사용권 발급을
/// 막고 기존 사용권이 모두 돌아온 뒤 한 호출만 교체를 수행한다 (PLAN §12).
actor ModelLifetimeCoordinator {
    enum Admission: Equatable, Sendable {
        case current
        case switchOwner
    }

    private var currentModelID: String?
    private var switching = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }
    private var switchWaiters: [Waiter] = []
    private var drainWaiters: [Waiter] = []

    /// Reserve only an existing stable model; never wait for or initiate a model switch/load.
    func reserveReadyOperation(modelID: String) -> Bool {
        guard !Task.isCancelled, !switching, currentModelID == modelID, operationCounter.snapshot == 0 else { return false }
        operationCounter.add(1); return true
    }

    func acquire(modelID: String, reservingOperation: Bool) async throws -> Admission {
        try Task.checkCancellation()
        while switching {
            try await wait(in: .switchQueue)
        }
        if currentModelID == modelID {
            try Task.checkCancellation()
            if reservingOperation { operationCounter.add(1) }
            return .current
        }

        switching = true
        do {
            while operationCounter.snapshot > 0 {
                try await wait(in: .drainQueue)
            }
            try Task.checkCancellation()
            return .switchOwner
        } catch {
            abandonSwitch()
            throw error
        }
    }

    func finishSwitch(
        to modelID: String, succeeded: Bool, reservingOperation: Bool
    ) {
        precondition(switching)
        currentModelID = succeeded ? modelID : nil
        if succeeded, reservingOperation { operationCounter.add(1) }
        switching = false
        let waiters = switchWaiters
        switchWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.continuation.resume() }
    }

    func releaseOperation() {
        precondition(operationCounter.snapshot > 0)
        operationCounter.add(-1)
        guard operationCounter.snapshot == 0 else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.continuation.resume() }
    }

    /// 종료 훅(AppDelegate)이 액터 진입 없이 읽는다. willTerminate 같은 비동기
    /// 불가 컨텍스트에서는 Swift 동시성 스케줄링이 보장되지 않는다 — 스모크에서
    /// detached 태스크가 액터 진입 전 정지하는 것을 확인했다 (이슈 #65 Gate 0).
    nonisolated func snapshotCount() -> Int {
        operationCounter.snapshot
    }

    /// 활성 연산 카운터 — 원래 액터 격리로만 지켰지만, 종료 훅(AppDelegate)이
    /// willTerminate에서 액터 진입 없이 읽어야 한다(스모크에서 detached 태스크가
    /// 액터 진입 전 정지하는 것을 확인). 모든 접근이 잠금 안이라
    /// `@unchecked Sendable`이 안전하다 (이슈 #65 Gate 0).
    private final class OperationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func add(_ delta: Int) {
            lock.lock()
            value += delta
            lock.unlock()
        }

        var snapshot: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let operationCounter = OperationCounter()

    func cancelSwitch() {
        abandonSwitch()
    }

    /// 종료 경로용 드레인 대기 — 활성 연산이 모두 반환(0)될 때까지 멈춘다.
    /// 호출자는 먼저 진행 중 생성의 부모 태스크를 취소해 둔다. 취소로 물러난
    /// 연산은 `releaseOperation`으로 돌아오고 그 신호(drainQueue 재개)로 깨어난다.
    /// 이 대기 없이 프로세스가 내려가면 mlx eval 스레드와 Metal 객체 해제가
    /// 겹쳐 teardown 세그폴트가 난다 (이슈 #65 Gate 0 스모크에서 재현).
    func waitUntilDrained() async {
        guard operationCounter.snapshot > 0 else { return }
        await withCheckedContinuation { continuation in
            let waiter = Waiter(id: UUID(), continuation: continuation)
            drainWaiters.append(waiter)
        }
    }

    private enum WaitQueue: Sendable {
        case switchQueue
        case drainQueue
    }

    private func wait(in queue: WaitQueue) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                let waiter = Waiter(id: id, continuation: continuation)
                switch queue {
                case .switchQueue: switchWaiters.append(waiter)
                case .drainQueue: drainWaiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id, in: queue) }
        }
        try Task.checkCancellation()
    }

    private func cancelWaiter(id: UUID, in queue: WaitQueue) {
        switch queue {
        case .switchQueue:
            guard let index = switchWaiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = switchWaiters.remove(at: index)
            waiter.continuation.resume()
        case .drainQueue:
            guard let index = drainWaiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = drainWaiters.remove(at: index)
            waiter.continuation.resume()
        }
    }

    private func abandonSwitch() {
        precondition(switching)
        switching = false
        let waiters = switchWaiters
        switchWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.continuation.resume() }
    }
}

/// 온디바이스 자동완성 추론 엔진 (M2/M3·M5, PLAN §4·§10·§12).
///
/// - 모델은 **1회 lazy 로드** 후 상주. 모델 id가 바뀌면 교체 로드.
/// - 프롬프트는 조립기(`ContextAssembler`)가 만든 `AssembledPrompt`만 받는다 —
///   엔진은 조립에 관여하지 않는다 (PLAN §10).
/// - `complete(prompt:parameters:)`는 **취소 가능**: 호출 태스크가 취소되면
///   토큰 스트림 소비를 끝내고 내부 생성 태스크도 명시적으로 취소·종료 대기한다.
/// - 이어쓰기(continuation) 경로는 직전 요청과의 공통 접두 KV를 재사용해
///   새 토큰만 증분 프리필한다 (PLAN §12 — `PromptCacheBox`).
/// - 토큰 상한(기본 12) + **문장 경계 조기 종료**로 단어/구 단위 제안을 보장.
public actor CompletionEngine {

    /// 로드된 모델의 토큰 카운터 스냅샷 (#43) — 조립기(메인)가 프롬프트 예산을
    /// 판정하는 데 쓴다. **원시 토크나이저는 경계를 넘지 않는다**: 카운트 클로저만
    /// Sendable 값으로 통과한다 (메타 이슈 #65 Phase 4 — "토큰 카운터 스냅샷 주입").
    /// 모델이 로드 전이면 nil — 호출부는 현행 문자 상수를 쓴다 (동작 불변).
    public func makeTokenCounter(expectedModelID: String? = nil) async -> TokenCounter? {
        guard let container, expectedModelID == nil || expectedModelID == loadedModelID else { return nil }
        return await container.perform { context in
            let tokenizer = context.tokenizer
            return TokenCounter({ tokenizer.encode(text: $0).count }, promptCost: { prompt in
                switch prompt {
                case .continuation(let text): return tokenizer.encode(text: text).count
                case .instruct(let system, let user):
                    do {
                        return try tokenizer.applyChatTemplate(messages: [
                            ["role": "system", "content": system], ["role": "user", "content": user]
                        ], tools: nil, additionalContext: ["enable_thinking": false]).count
                    } catch let error as Tokenizers.TokenizerError {
                        switch error {
                        case .missingChatTemplate:
                            // Match the loaded dependency's LLMUserInputProcessor fallback.
                            return tokenizer.encode(text: system + "\n\n" + user).count
                        default: return .max
                        }
                    } catch { return .max }
                }
            })
        }
    }

    struct TextObservation {
        private(set) var text = ""
        private(set) var rawText = ""
        mutating func append(_ chunk: String, stopAtUtteranceEnd: Bool) -> Bool {
            rawText += chunk; text += chunk
            let cut = stopAtUtteranceEnd ? CompletionEngine.cutAtUtteranceEnd(text) : CompletionEngine.cutAtSentenceBoundary(text)
            if let cut { text = cut; return true }
            return false
        }
        func displayed(style: PromptStyle) -> String { CompletionEngine.postProcess(text, style: style) }
    }

    /// 한 번의 자동완성 결과 + 지연 측정치(M2 로그·상태 바 표시용).
    public struct Completion: Sendable {
        /// 고스트로 띄울 제안 텍스트(후처리 완료). 비어 있으면 "제안 없음".
        public let text: String
        /// 생성 시작 → 첫 텍스트 청크까지 (모델 로드 시간 제외).
        public let timeToFirstChunk: TimeInterval?
        /// 생성 시작 → 종료(문장 경계 조기 종료 포함).
        public let totalTime: TimeInterval
        /// 자연 종료(EOS·토큰 상한)일 때만 채워지는 처리량 정보.
        public let promptTokensPerSecond: Double?
        public let generationTokensPerSecond: Double?
        /// 문장 경계에서 조기 종료했는지.
        public let stoppedAtSentenceBoundary: Bool
        /// 프롬프트 전체 토큰 수 (클램프 후) — 벤치·예산 튜닝용 (PLAN §13).
        public let promptTokenCount: Int
        /// KV 재사용으로 프리필을 건너뛴 토큰 수 (PLAN §12 효과 측정).
        public let reusedPromptTokens: Int
        @_spi(Benchmark) public var rawText = ""
        @_spi(Benchmark) public var timeToFirstToken: TimeInterval? = nil

        static let empty = Completion(
            text: "",
            timeToFirstChunk: nil,
            totalTime: 0,
            promptTokensPerSecond: nil,
            generationTokensPerSecond: nil,
            stoppedAtSentenceBoundary: false,
            promptTokenCount: 0,
            reusedPromptTokens: 0
        )
    }

    private var container: ModelContainer?
    private var loadedModelID: String?
    private var loadTask: Task<ModelContainer, Error>?
    private var loadingModelID: String?
    /// `loadedContainer` 반환과 `container.perform` 시작 사이의 actor 재진입까지
    /// 포함해 모델 교체와 기존 생성의 수명을 직렬화한다 (PLAN §12).
    private let modelLifetime: ModelLifetimeCoordinator
    /// 이어쓰기 프리필 KV 재사용 (PLAN §12). 모델 교체 시 폐기.
    private let promptCache = PromptCacheBox()

    private let memoryPolicy: ModelMemoryPolicy
    public init(memoryPolicy: ModelMemoryPolicy = .current) {
        self.memoryPolicy = memoryPolicy; self.modelLifetime = ModelLifetimeCoordinator()
    }
    init(memoryPolicy: ModelMemoryPolicy, modelLifetime: ModelLifetimeCoordinator) {
        self.memoryPolicy = memoryPolicy; self.modelLifetime = modelLifetime
    }
    /// Drain every operation before retiring model identity and its KV context.
    public func unload() async throws {
        loadTask?.cancel()
        _ = try await modelLifetime.acquire(modelID: "unload/" + UUID().uuidString, reservingOperation: false)
        let retiringLoad = loadTask, retiringContainer = container
        loadTask = nil; loadingModelID = nil; container = nil; loadedModelID = nil
        promptCache.invalidate()
        retiringLoad?.cancel()
        if let retiringLoad { _ = try? await retiringLoad.value }
        if let retiringContainer { await retiringContainer.perform { _ in () } }
        await modelLifetime.finishSwitch(to: "", succeeded: false, reservingOperation: false)
    }

    /// 모델을 미리 로드한다(앱 시작 시 호출 — 첫 제안 지연 방지).
    /// 이미 같은 모델이 로드돼 있으면 즉시 반환.
    public func preload(
        parameters: CompletionParameters,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        _ = try await loadedContainer(
            modelID: parameters.modelID, onProgress: onProgress,
            reservingOperation: false)
    }

    /// 프롬프트 KV 캐시를 폐기한다 — 다음 생성은 무조건 콜드 프리필이다.
    /// 모델 교체 외의 무효화 지점(메모리 압박·벤치의 콜드 기준선 복원)용 (PLAN §12).
    public func resetPromptCache() {
        promptCache.invalidate()
    }

    /// 앱 종료 직전의 정리 대기. 진행 중 생성·프리필의 부모 태스크를 취소한
    /// **뒤** 호출해야 빨리 드레인된다(취소 없이 기다리면 생성이 끝날 때까지
    /// 종료가 막힌다). 반환 시점에는 GPU에 Purlory가 건 활성 연산이 없으므로,
    /// 이후 프로세스 teardown이 mlx eval 스레드와 경합하지 않는다.
    public func shutdown() async {
        await modelLifetime.waitUntilDrained()
    }

    /// 종료 훅용 동기 스냅샷 — willTerminate 같은 비동기 불가 컨텍스트에서
    /// 액터 진입 없이 드레인 여부를 읽는다 (이슈 #65 Gate 0).
    nonisolated public var pendingOperationCount: Int {
        modelLifetime.snapshotCount()
    }

    /// 조립된 프롬프트로 다음 단어/구를 생성한다 (PLAN §10).
    ///
    /// 호출 태스크 취소에 즉시 협조한다 — 새 키 입력 시 컨트롤러가 태스크를
    /// 취소하면 진행 중 생성도 함께 멈춘다.
    public func complete(
        prompt: AssembledPrompt,
        parameters: CompletionParameters,
        onLoadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Completion {
        if case .continuation(let text) = prompt,
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .empty
        }
        let cache = promptCache
        return try await withLoadedContainer(
            modelID: parameters.modelID, onProgress: onLoadProgress
        ) { container in
            try Task.checkCancellation()
            return try await Self.runGeneration(
                in: container, prompt: prompt, parameters: parameters,
                promptCache: cache)
        }
    }

    /// PurloryBench 전용: 내부 token loop가 만들어진 정확한 시점을 알려, 콜드
    /// 프리필 도중이 아니라 생성 진행 중 취소를 재현한다 (PLAN §12).
    package func completeForCancellationStress(
        prompt: AssembledPrompt,
        parameters: CompletionParameters,
        stopAfterFirstChunk: Bool = false,
        onGenerationStarted: @escaping @Sendable () -> Void
    ) async throws -> Completion {
        let cache = promptCache
        return try await withLoadedContainer(
            modelID: parameters.modelID, onProgress: nil
        ) { container in
            try Task.checkCancellation()
            return try await Self.runGeneration(
                in: container, prompt: prompt, parameters: parameters,
                promptCache: cache,
                onGenerationStarted: onGenerationStarted,
                stopAfterFirstChunk: stopAfterFirstChunk)
        }
    }

    /// 폴더 멤버 문서들의 내용에서 짧은 폴더 이름을 생성한다 (사이드바 DnD 1.4).
    ///
    /// promptStyle 설정과 무관하게 항상 instruct 챗으로 실행 — 이어쓰기는 이름
    /// 짓기에 맞지 않는다. 자동완성과 같은 컨테이너를 공유한다(모델 이중 로드 없음).
    /// 프롬프트 캐시에는 손대지 않는다 — 예측의 프리픽스가 식지 않는다.
    /// 빈 문자열을 반환하면 호출부가 기본 이름("새 폴더")을 유지한다.
    public func generateFolderName(
        content: String,
        parameters: CompletionParameters
    ) async throws -> String {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return try await withLoadedContainer(
            modelID: parameters.modelID, onProgress: nil
        ) { container in
            try Task.checkCancellation()
            return try await container.perform { context in
                let chat: [Chat.Message] = [
                    .system(Prompting.folderNameSystem),
                    .user(Prompting.folderNameUser(content: content)),
                ]
                let userInput = UserInput(
                    chat: chat, additionalContext: ["enable_thinking": false])
                let input = try await context.processor.prepare(input: userInput)
                try Task.checkCancellation()

                let generateParameters = GenerateParameters(
                    maxTokens: 16,
                    temperature: Float(parameters.temperature),
                    topP: Float(parameters.topP)
                )

                var text = ""
                let (stream, synchronizer) = try Self.generationTask(
                    input: input, parameters: generateParameters, context: context)
                for await generation in stream {
                    if Task.isCancelled { break }
                    if case .chunk(let chunk) = generation {
                        text += chunk
                        // 이름은 한 줄 — 내용이 생긴 뒤 줄바꿈이 나오면 그만 받는다
                        // (문장 경계 로직은 이름의 마침표 오검출 위험이 있어 안 쓴다).
                        if text.contains("\n"),
                            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            break
                        }
                    }
                }
                await synchronizer.cancelAndWait()
                try Task.checkCancellation()
                return Self.cleanFolderName(text)
            }
        }
    }

    /// 백그라운드 이해 파이프라인의 일회성 instruct 호출 (M6, PLAN §9) —
    /// 씬 요약·장 요약·인물 프로파일링이 이 하나로 통한다.
    ///
    /// `generateFolderName`과 같은 규율: 항상 instruct 챗, 프롬프트 캐시 불가침
    /// (예측의 프리픽스가 식지 않는다), 협조 취소(타이핑 재개 → 인덱서가 태스크를
    /// 취소하면 다음 청크에서 멈춘다). 실패·빈 결과는 호출부가 무시한다 —
    /// 백그라운드 실패는 다음 패스가 다시 시도하면 그만이다.
    /// `stopAtBlankLine`: 기본 true — 요약처럼 한 문단만 받을 때 빈 줄(문단
    /// 경계)에서 조기 종료한다. 씬 분석·심화 추출처럼 **여러 줄** 형식을 받는
    /// 호출은 false로 넘긴다 — 모델이 항목 사이에 빈 줄을 넣어도 출력이 중간에
    /// 끊기지 않는다 (이해 타임라인 텍스트 잘림의 원인 중 하나였다).
    public func generateOneShot(
        system: String,
        user: String,
        maxTokens: Int,
        parameters: CompletionParameters,
        stopAtBlankLine: Bool = true
    ) async throws -> String {
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return try await withLoadedContainer(
            modelID: parameters.modelID, onProgress: nil
        ) { container in
            try Task.checkCancellation()
            return try await container.perform { context in
                let chat: [Chat.Message] = [.system(system), .user(user)]
                let userInput = UserInput(
                    chat: chat, additionalContext: ["enable_thinking": false])
                let input = try await context.processor.prepare(input: userInput)
                try Task.checkCancellation()

                let generateParameters = GenerateParameters(
                    maxTokens: maxTokens,
                    temperature: Float(parameters.temperature),
                    topP: Float(parameters.topP)
                )

                var text = ""
                let (stream, synchronizer) = try Self.generationTask(
                    input: input, parameters: generateParameters, context: context)
                for await generation in stream {
                    if Task.isCancelled { break }
                    if case .chunk(let chunk) = generation {
                        text += chunk
                        // 요약은 한 문단 — 내용이 생긴 뒤 빈 줄(문단 경계)이 나오면
                        // 그만 받는다 (설명·부연이 이어지는 걸 끊는다).
                        if stopAtBlankLine,
                            text.contains("\n\n"),
                            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            break
                        }
                    }
                }
                await synchronizer.cancelAndWait()
                try Task.checkCancellation()
                let cleaned = Self.stripThinking(text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Self.stripSurroundingQuotes(cleaned)
            }
        }
    }

    package enum ReadyInstructionError: Error, Equatable { case modelUnavailable, promptTooLong, unsupportedResponse }

    /// Optional explicit answers never trigger model setup and use fresh instruction state.
    package func streamInstructionIfReady(system: String, user: String, parameters: CompletionParameters,
                                  onChunk: @escaping @Sendable (String) throws -> Void) async throws {
        guard let loaded = container, !parameters.modelID.isEmpty, loadedModelID == parameters.modelID,
              await modelLifetime.reserveReadyOperation(modelID: parameters.modelID) else { throw ReadyInstructionError.modelUnavailable }
        do {
            // Reservation is an actor hop: a same-ID reset may have replaced the container.
            guard container === loaded, loadedModelID == parameters.modelID else { throw ReadyInstructionError.modelUnavailable }
            try Task.checkCancellation()
            try await loaded.perform { context in
                let input = try await context.processor.prepare(input: UserInput(
                    chat: [.system(system), .user(user)], additionalContext: ["enable_thinking": false]))
                guard ReadyInstructionLimits.promptFits(count: input.text.tokens.size, budget: parameters.maxPromptTokens) else { throw ReadyInstructionError.promptTooLong }
                try Task.checkCancellation()
                let generationParameters = GenerateParameters(maxTokens: 512, temperature: 0, topP: 1, prefillStepSize: 128)
                let (stream, synchronizer) = try Self.generationTask(input: input, parameters: generationParameters, context: context)
                var iterator = stream.makeAsyncIterator()
                do {
                    while let value = await iterator.next() {
                        try Task.checkCancellation()
                        switch value {
                        case .chunk(let chunk): try onChunk(chunk)
                        case .info: break
                        case .toolCall, .rejectedToolCall: throw ReadyInstructionError.unsupportedResponse
                        }
                    }
                } catch {
                    _ = await synchronizer.cancelAndCollectInfo(from: &iterator)
                    throw error
                }
                _ = await synchronizer.cancelAndCollectInfo(from: &iterator)
                try Task.checkCancellation()
            }
            await modelLifetime.releaseOperation()
        } catch { await modelLifetime.releaseOperation(); throw error }
    }

    // MARK: - 모델 로드 (1회, 교체 가능)

    /// 모델 사용권을 생성 전체 수명 동안 유지한다. 교체 요청은 이 사용권이
    /// 반환될 때까지 기다리므로 `loadedContainer` 반환 직후의 재진입 창도 없다.
    private func withLoadedContainer<Result: Sendable>(
        modelID: String,
        onProgress: (@Sendable (Double) -> Void)?,
        operation: @Sendable (ModelContainer) async throws -> Result
    ) async throws -> Result {
        let loaded = try await loadedContainer(
            modelID: modelID, onProgress: onProgress,
            reservingOperation: true)
        do {
            let result = try await operation(loaded)
            await modelLifetime.releaseOperation()
            return result
        } catch {
            await modelLifetime.releaseOperation()
            throw error
        }
    }

    private func loadedContainer(
        modelID: String,
        onProgress: (@Sendable (Double) -> Void)?,
        reservingOperation: Bool
    ) async throws -> ModelContainer {
        guard let manifest = PinnedModelCatalog.manifest(for: modelID) else { throw ModelInstallError.metadata }
        try memoryPolicy.requireLoad(manifest: manifest)
        let admission = try await modelLifetime.acquire(
            modelID: modelID, reservingOperation: reservingOperation)
        do {
            try Task.checkCancellation()
        } catch {
            if admission == .switchOwner {
                await modelLifetime.cancelSwitch()
            } else if reservingOperation {
                await modelLifetime.releaseOperation()
            }
            throw error
        }
        if admission == .current {
            // 조정기와 실제 컨테이너 상태는 같은 switch owner만 함께 갱신한다.
            guard let container, loadedModelID == modelID else {
                preconditionFailure("모델 수명주기 상태와 컨테이너가 불일치합니다")
            }
            return container
        }

        // 교체권을 얻은 시점에는 기존 perform 사용권이 모두 반환됐다. 게시된
        // 컨테이너를 먼저 내리고, 취소한 로드와 Metal 큐를 모두 기다린다.
        let retiringContainer = container
        let retiringLoad = loadTask
        container = nil
        loadedModelID = nil
        loadTask = nil
        loadingModelID = nil
        promptCache.invalidate()
        retiringLoad?.cancel()
        if let retiringLoad { _ = try? await retiringLoad.value }
        if let retiringContainer { await retiringContainer.perform { _ in () } }

        let task = Task { try await Self.load(modelID: modelID, onProgress: onProgress) }
        loadTask = task
        loadingModelID = modelID
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            container = loaded
            loadedModelID = modelID
            loadTask = nil
            loadingModelID = nil
            await modelLifetime.finishSwitch(
                to: modelID, succeeded: true,
                reservingOperation: reservingOperation)
            return loaded
        } catch {
            // `task.value`가 돌아왔으므로 취소된 로드도 실제 종료된 상태다.
            loadTask = nil
            loadingModelID = nil
            await modelLifetime.finishSwitch(
                to: modelID, succeeded: false,
                reservingOperation: false)
            throw error
        }
    }

    private static func load(
        modelID: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> ModelContainer {
        guard let manifest = PinnedModelCatalog.manifest(for: modelID) else { throw ModelInstallError.metadata }
        try Self.mlxConfigured.get()
        let directory = try await ModelInstallationStore.shared.install(manifest, download: ModelDownloadManager.transfer) { _, fraction in
            onProgress?(fraction)
        }
        try Task.checkCancellation()
        return try await loadModelContainer(from: directory, using: LocalTokenizerLoader())
    }

    @_spi(Benchmark) public nonisolated static var benchmarkMLXPeakBytes: UInt64 { UInt64(Memory.peakMemory) }

    /// Validate and initialize once at model load, before configuring MLX memory.
    private static let mlxConfigured: Result<Void, Error> = Result {
        try MLXRuntimeResources.initialize()
        Memory.cacheLimit = 256 * 1024 * 1024
    }

    // MARK: - 생성

    private static func runGeneration(
        in container: ModelContainer,
        prompt: AssembledPrompt,
        parameters: CompletionParameters,
        promptCache: PromptCacheBox,
        onGenerationStarted: (@Sendable () -> Void)? = nil,
        stopAfterFirstChunk: Bool = false
    ) async throws -> Completion {
        let start = Date()
        return try await container.perform { context in
            let generateParameters = GenerateParameters(
                maxTokens: parameters.maxTokens,
                temperature: Float(parameters.temperature),
                topP: Float(parameters.topP)
            )

            let input: LMInput
            let style: PromptStyle
            var kvCache: [KVCache]?
            var promptTokenCount = 0
            var reusedPromptTokens = 0
            var cacheLease: PromptCacheBox.Lease?

            switch prompt {
            case .continuation(let text):
                style = .continuation
                // 챗 템플릿을 거치지 않고 조립된 텍스트를 그대로 이어쓴다.
                // 어절 중간("나는 오…")에서도 이어짐 + 선행 공백이 보존된다.
                var tokens = context.tokenizer.encode(text: text)
                // 토큰 안전 예산 (PLAN §11) — 문자 창이 과할 때만 발동. 잘라낼 때도
                // 512 격자 단위로 잘라, 다음 요청과의 공통 접두가 유지되게 한다.
                if tokens.count > parameters.maxPromptTokens {
                    let overflow = tokens.count - parameters.maxPromptTokens
                    let drop = min(((overflow + 511) / 512) * 512, tokens.count - 1)
                    tokens = Array(tokens.dropFirst(drop))
                }
                promptTokenCount = tokens.count
                if parameters.kvCacheEnabled,
                    let reuse = try promptCache.begin(
                        modelID: parameters.modelID, tokens: tokens,
                        model: context.model, parameters: generateParameters)
                {
                    kvCache = reuse.cache
                    reusedPromptTokens = reuse.reusedTokens
                    cacheLease = reuse.lease
                    input = LMInput(tokens: MLXArray(reuse.suffix))
                } else {
                    input = LMInput(tokens: MLXArray(tokens))
                }
            case .instruct(let system, let user):
                style = .instruct
                let chat: [Chat.Message] = [.system(system), .user(user)]
                // Qwen3 계열의 사고(thinking) 모드는 자동완성에 불필요 — 끈다.
                let userInput = UserInput(
                    chat: chat, additionalContext: ["enable_thinking": false])
                input = try await context.processor.prepare(input: userInput)
                promptTokenCount = input.text.tokens.size
                // instruct는 챗 템플릿이 본문 뒤에도 토큰을 붙여 LCP 이득이 작다 —
                // KV 재사용은 이어쓰기 경로만 (PLAN §12, M5 범위).
            }

            do {
                try Task.checkCancellation()

                var observation = TextObservation()
                var timeToFirstChunk: TimeInterval?
                var info: GenerateCompletionInfo?
                var stoppedAtBoundary = false
                var stoppedAfterFirstChunk = false

                let (stream, synchronizer) = try Self.generationTask(
                    input: input, cache: kvCache, parameters: generateParameters,
                    context: context)
                onGenerationStarted?()
                var iterator = stream.makeAsyncIterator()
                while let generation = await iterator.next() {
                    if Task.isCancelled { break }
                    switch generation {
                    case .chunk(let chunk):
                        if timeToFirstChunk == nil {
                            timeToFirstChunk = Date().timeIntervalSince(start)
                        }
                        stoppedAtBoundary = observation.append(chunk, stopAtUtteranceEnd: parameters.stopAtUtteranceEnd)
                        if stopAfterFirstChunk { stoppedAfterFirstChunk = true }
                    case .info(let generationInfo):
                        info = generationInfo
                    case .toolCall, .rejectedToolCall:
                        break
                    }
                    // 루프 이탈 뒤 아래에서 내부 생성 Task를 취소·종료 대기한다.
                    if stoppedAtBoundary || stoppedAfterFirstChunk { break }
                }
                // Join before handing off the cache/container. Final timing is
                // retained even when sentence cutting stops text consumption.
                let finalInfo = await synchronizer.cancelAndCollectInfo(from: &iterator)
                // Only the drained lease can publish its captured prompt prefix.
                if let lease = cacheLease {
                    promptCache.commit(lease: lease)
                    // A later cancellation check must not abandon an already retired lease.
                    cacheLease = nil
                }
                try Task.checkCancellation()

                return Completion(
                    text: observation.displayed(style: style),
                    timeToFirstChunk: timeToFirstChunk,
                    totalTime: Date().timeIntervalSince(start),
                    promptTokensPerSecond: info?.promptTokensPerSecond,
                    generationTokensPerSecond: info?.tokensPerSecond,
                    stoppedAtSentenceBoundary: stoppedAtBoundary,
                    promptTokenCount: promptTokenCount,
                    reusedPromptTokens: reusedPromptTokens,
                    rawText: observation.rawText,
                    timeToFirstToken: (info ?? finalInfo)?.benchmarkTimeToFirstToken
                )
            } catch {
                // Cooperative cancellation may preserve this lease's proven prefix;
                // other failures discard it. Reset/model retirement makes either operation
                // a no-op for an obsolete lease, protecting any newer generation's state.
                if let lease = cacheLease {
                    if error is CancellationError {
                        promptCache.commit(lease: lease)
                    } else {
                        promptCache.abandon(lease: lease)
                    }
                }
                throw error
            }
        }
    }

    /// 고수준 `generate()`가 숨기는 내부 Task까지 소유해 조기 종료 경로가
    /// 명시적으로 cancel 후 await할 수 있게 한다 (PLAN §12).
    private static func generationTask(
        input: LMInput,
        cache: [KVCache]? = nil,
        parameters: GenerateParameters,
        context: ModelContext
    ) throws -> (AsyncStream<Generation>, GenerationTaskSynchronizer) {
        let iterator = try TokenIterator(
            input: input, model: context.model, cache: cache,
            parameters: parameters)
        let (stream, task) = MLXLMCommon.generateTask(
            promptTokenCount: input.text.tokens.size,
            modelConfiguration: context.configuration,
            tokenizer: context.tokenizer,
            iterator: iterator)
        return (stream, GenerationTaskSynchronizer(task: task))
    }

    // MARK: - 프롬프트 (폴더 명명 전용 — 자동완성 프롬프트는 ContextAssembler 소유)

    private enum Prompting {
        static let folderNameSystem = """
            너는 문서 묶음에 어울리는 폴더 이름을 짓는 도우미다. \
            문서들의 공통 주제를 담은 짧은 한국어 폴더 이름(2~5단어, 명사형)을 \
            하나만 출력한다. 설명·번호·따옴표·마침표 없이 이름만 출력한다.
            """

        static func folderNameUser(content: String) -> String {
            """
            다음 문서들을 담을 폴더의 이름을 지어라.

            \(content)
            """
        }
    }

    // MARK: - 후처리

    /// 문장 경계 문자(포함)까지 자른다. 없으면 nil.
    /// 단어/구 단위 제안 원칙 — 최대 한 문장에서 멈춘다 (PLAN §10 정지 사다리).
    private static let sentenceBoundaries: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？", "\n",
    ]

    private static func cutAtSentenceBoundary(_ text: String) -> String? {
        guard let index = text.firstIndex(where: { sentenceBoundaries.contains($0) })
        else { return nil }
        return String(text[...index])
    }

    /// 발화 끝 문자 — 대화 모드의 정지 조건 (PLAN §10). 닫는 따옴표(포함)까지
    /// 자른다. 개행은 안전 바닥 — 모델이 따옴표를 안 닫고 문단을 넘어가면 끊는다.
    private static let utteranceBoundaries: Set<Character> = [
        "”", "\"", "」", "』", "\n",
    ]

    private static func cutAtUtteranceEnd(_ text: String) -> String? {
        guard let index = text.firstIndex(where: { utteranceBoundaries.contains($0) })
        else { return nil }
        return String(text[...index])
    }

    private static func postProcess(_ raw: String, style: PromptStyle) -> String {
        var text = raw
        if style == .instruct {
            text = stripThinking(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = stripSurroundingQuotes(text)
        } else {
            text = stripContinuationThinking(text)
        }
        // 고스트는 한 줄만 그린다 — 첫 줄바꿈 이전까지만.
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline])
        }
        // 끝쪽 공백 정리. 선행 공백은 continuation에서 어절 경계 정보라 보존한다.
        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }
        return text
    }

    /// 이어쓰기 출력의 사고(thinking) 태그 제거 — 사고 학습 모델(Qwen3.5 계열)은
    /// 챗 템플릿 없는 이어쓰기에서도 `<think>…</think>` 블록이나 홀로 닫는
    /// `</think>`를 내보낸다 (벤치 2026-08-22: Ternary-Bonsai 제안이 "</think>"
    /// 그 자체였음). 태그로 시작할 때만 벗겨 뒤의 본문을 남긴다 — 일반 출력과
    /// 본문 중간의 태그는 건드리지 않는다. 닫히지 않은 사고 블록은 빈 제안.
    static func stripContinuationThinking(_ text: String) -> String {
        let stripped = text.drop(while: { $0.isWhitespace || $0.isNewline })
        guard stripped.hasPrefix("<think>") || stripped.hasPrefix("</think>") else {
            return text
        }
        let rest = String(stripped)
        if let range = rest.range(of: "</think>") {
            return String(rest[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// 폴더 이름 후처리 — 모델 출력에서 깨끗한 한 줄 이름만 남긴다.
    /// 빈 결과를 반환하면 호출부가 기본 이름("새 폴더")을 유지한다.
    private static func cleanFolderName(_ raw: String) -> String {
        var text = stripThinking(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline])
        }
        text = stripSurroundingQuotes(text.trimmingCharacters(in: .whitespaces))
        // 앞머리 마크다운·불릿·번호 마커만 벗긴다 — 마커 뒤 공백을 요구해
        // "2024.03 회고"처럼 숫자·점으로 시작하는 정상 이름은 건드리지 않는다.
        text = text.replacingOccurrences(
            of: #"^(?:#{1,6}\s+|[-*•]\s+|\d+[.)]\s+|>\s+)+"#,
            with: "", options: .regularExpression)
        // 끝쪽 문장부호·공백 정리 — "이름만" 규칙을 모델이 어겨도 복구.
        let trailing: Set<Character> = [
            ".", "。", "!", "！", "?", "？", "…", ",", "，", ":", "：",
        ]
        while let last = text.last, trailing.contains(last) || last.isWhitespace {
            text.removeLast()
        }
        // 내부 공백 뭉치는 하나로.
        text = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        return String(text.prefix(20)).trimmingCharacters(in: .whitespaces)
    }

    /// Qwen3 계열이 `<think>…</think>`를 앞에 붙이는 경우 제거.
    /// 닫히지 않은 사고 출력은 본문이 아니므로 통째로 버린다.
    private static func stripThinking(_ text: String) -> String {
        let trimmed = text.drop(while: { $0.isWhitespace || $0.isNewline })
        guard trimmed.hasPrefix("<think>") else { return text }
        guard let end = trimmed.range(of: "</think>") else { return "" }
        return String(trimmed[end.upperBound...])
    }

    /// 양끝이 모두 따옴표로 감싸졌을 때만 벗긴다(instruct 응답 정리).
    private static func stripSurroundingQuotes(_ text: String) -> String {
        let quotes: Set<Character> = ["\"", "“", "”", "'", "‘", "’"]
        guard text.count >= 2,
            let first = text.first, let last = text.last,
            quotes.contains(first), quotes.contains(last)
        else { return text }
        return String(text.dropFirst().dropLast())
    }
}
