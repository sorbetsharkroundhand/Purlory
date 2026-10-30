import Combine
import Foundation
import PurloryKoreanBackend

/// App-owned offline diagnostics lifetime; the native model remains lazy until admitted work.
@MainActor
public final class WritingDiagnosticsRuntime: ObservableObject {
    @Published private(set) var isReleasingNative = false
    let controller: WritingDiagnosticsController
    private let worker: KoreanNativeWorker
    private let reader: WritingRuntimeSnapshotReader
    private var releaseTask: Task<Void, Never>?
    private var pressure = MemoryPressureLevel.normal
    private var sharedBackgroundPaused = false
    private var terminated = false
    private var observations = Set<AnyCancellable>()
    private var workspaceBinding: WritingDiagnosticsWorkspaceBinding?
    @Published private(set) var actionMessage: String?

    public convenience init() { self.init(observeEnergy: true) }
    convenience init(observeEnergy: Bool) {
        self.init(worker: KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL), observeEnergy: observeEnergy)
    }
    init(worker: KoreanNativeWorker, observeEnergy: Bool, clock: any WritingDiagnosticsClock = ContinuousWritingDiagnosticsClock()) {
        self.worker = worker
        let reader = WritingRuntimeSnapshotReader(); self.reader = reader
        let provider = KoreanDiagnosticsProvider(morphology: KoreanMorphology(worker: worker))
        controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock,
            currentSnapshot: { reader.current() }, ruleRevision: KoreanDiagnosticsProvider.ruleRevision, reportProvider: provider)
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        if observeEnergy {
            let names: [Notification.Name] = [.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
            for name in names {
                NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                    Task { @MainActor in self?.refreshEnergyPolicy() }
                }.store(in: &observations)
            }
            refreshEnergyPolicy()
        }
    }
    func configure(currentSnapshot: @escaping @MainActor () -> ProjectDocumentSnapshot?) { reader.provider = currentSnapshot }
    func connect(session: ProjectSession, editorBridge: ProjectEditorBridge, livingMargin: LivingMarginModel) {
        guard !terminated else { return }
        configure(currentSnapshot: { [weak session] in session?.selectedDocumentSnapshot })
        if let workspaceBinding, workspaceBinding.matches(session: session, bridge: editorBridge, margin: livingMargin) {
            workspaceBinding.refresh(); return
        }
        workspaceBinding?.stop()
        let binding = WritingDiagnosticsWorkspaceBinding(controller: controller, session: session, bridge: editorBridge, margin: livingMargin)
        workspaceBinding = binding; binding.connect()
    }
    func waitForPresentation() async { await workspaceBinding?.waitForPublication() }
    func navigateMarginEvidence(insightID: String, evidence: EvidenceAnchor, requests: ProjectEditorRequests) -> Bool {
        let succeeded = workspaceBinding?.navigate(insightID: insightID, evidence: evidence, requests: requests) == true
        actionMessage = succeeded ? nil : "원문 위치를 확인할 수 없어요. 새 제안을 확인해 주세요."
        return succeeded
    }
    @discardableResult
    func performMarginAction(insightID: String, action: MarginAction) throws -> WritingCorrectionResult? {
        guard let workspaceBinding else { throw WritingDiagnosticsActionError.stale }
        do {
            let result = try workspaceBinding.perform(insightID: insightID, action: action)
            if case .some(.refused(let reason)) = result {
                switch reason {
                case .stale: actionMessage = "원문이나 설정이 바뀌었습니다. 새 제안을 확인해 주세요."
                case .composing: actionMessage = "입력을 마친 뒤 다시 선택해 주세요."
                case .unmapped, .ambiguous: actionMessage = "이 위치를 정확히 확인할 수 없어요. 원문을 확인해 주세요."
                case .formatting: actionMessage = "서식을 보존하며 바꿀 수 없는 제안이에요. 원문에서 직접 고쳐 주세요."
                }
            } else { actionMessage = nil }
            return result
        } catch {
            actionMessage = "원문이나 설정이 바뀌었습니다. 새 제안을 확인해 주세요."
            throw error
        }
    }
    func retry() { actionMessage = nil; controller.retry() }
    func setForegroundBusy(_ busy: Bool) { guard !terminated else { return }; controller.setForegroundBusy(busy) }
    func setEnergyPolicy(thermal: ProcessInfo.ThermalState, lowPower: Bool) {
        guard !terminated else { return }; controller.setEnergyPolicy(thermal: thermal, lowPower: lowPower)
    }
    private func refreshEnergyPolicy() {
        setEnergyPolicy(thermal: ProcessInfo.processInfo.thermalState, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    /// Synchronous event delivery closes admission before any release task can suspend.
    func noteMemoryPressure(_ next: MemoryPressureLevel) {
        guard !terminated else { return }
        pressure = next
        if next == .critical {
            controller.setMemoryPressure(.critical)
            worker.cancelPending()
            guard releaseTask == nil else { return }
            isReleasingNative = true
            let worker = worker
            releaseTask = Task { [weak self] in
                await worker.release()
                guard let self else { return }
                self.releaseTask = nil; self.isReleasingNative = false
                if !self.terminated { self.applyPressurePolicy() }
            }
        } else {
            applyPressurePolicy()
        }
    }
    func setSharedBackgroundPaused(_ paused: Bool) {
        guard sharedBackgroundPaused != paused else { return }
        sharedBackgroundPaused = paused; applyPressurePolicy()
    }
    private func applyPressurePolicy() {
        if releaseTask != nil { controller.setMemoryPressure(.critical) }
        else if sharedBackgroundPaused && pressure == .normal { controller.setMemoryPressure(.warning) }
        else { controller.setMemoryPressure(pressure) }
    }
    func waitForNativeRelease() async { await releaseTask?.value }
    func setMemoryPressure(_ level: MemoryPressureLevel) async {
        noteMemoryPressure(level)
        await releaseTask?.value
    }
    func prepareForProjectTransition() {
        workspaceBinding?.resetPublication(); actionMessage = nil
        controller.clearContext(); worker.cancelPending()
    }
    public func stop() {
        guard !terminated else { return }
        terminated = true; workspaceBinding?.stop(); workspaceBinding = nil; observations.removeAll()
        controller.clearContext(); worker.cancelPending(); reader.provider = nil
    }
    public func prepareForTermination() async {
        stop()
        if let releaseTask { await releaseTask.value }
        await worker.release()
        reader.provider = nil
    }
}

@MainActor
private final class WritingRuntimeSnapshotReader {
    var provider: (@MainActor () -> ProjectDocumentSnapshot?)?
    func current() -> ProjectDocumentSnapshot? { provider?() }
}
