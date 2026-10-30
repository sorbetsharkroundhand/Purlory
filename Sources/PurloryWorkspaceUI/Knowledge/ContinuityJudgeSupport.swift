import Combine
import Foundation

/// Shares only ready-runtime admission and an explicit generator, never an automatic queue.
@MainActor
final class ContinuityJudgeSupport: ObservableObject {
    @Published private(set) var available: Bool
    private let generate: ContinuityJudgeController.Generator
    private weak var completion: CompletionController?
    private final class Owner {
        weak var model: ContinuityJudgeController?
        init(_ model: ContinuityJudgeController) { self.model = model }
    }
    private var owners: [Owner] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var pressure = false, closed = false
    private var selectedModel = ""
    init(available: Bool, generate: @escaping ContinuityJudgeController.Generator) {
        self.available = available; self.generate = generate
    }
    func observe(_ completion: CompletionController) {
        guard !closed else { return }
        self.completion = completion
        Publishers.CombineLatest4(completion.$engineState, completion.$isMemoryPressurePaused,
            completion.$isManagingModel, completion.settings.$authorization)
            .combineLatest(Publishers.CombineLatest(completion.settings.$modelID, completion.settings.$autocompleteEnabled))
            .sink { [weak self] values, choice in
                guard let self, !self.closed else { return }
                let (modelID, enabled) = choice
                self.owners.removeAll { $0.model == nil }
                if self.selectedModel != modelID { self.owners.forEach { $0.model?.setModelAvailable(false) } }
                self.selectedModel = modelID; self.pressure = values.1
                let ready = AskPurlorySupport.admits(ready: values.0 == .ready, authorized: values.3 == .enabled,
                    enabled: enabled, managing: values.2, pressure: values.1, modelID: modelID)
                self.available = ready
                self.owners.forEach { $0.model?.setModelAvailable(ready) }
                self.refreshPolicy()
            }.store(in: &subscriptions)
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refreshPolicy()
            }.store(in: &subscriptions)
        }
    }
    func makeController(session: ProjectSession, origin: ProjectRuntimeIdentity) -> ContinuityJudgeController {
        let model = ContinuityJudgeController(session: session, origin: origin, modelAvailable: available && !closed, generate: generate)
        guard !closed else { model.dismiss(); return model }
        owners.append(Owner(model))
        completion?.observeForegroundCompletion(owner: model) { [weak model] busy in model?.setForegroundBusy(busy) }
        refreshPolicy(); return model
    }
    func shutdown() {
        guard !closed else { return }
        closed = true; available = false
        owners.forEach { $0.model?.dismiss() }; owners.removeAll(); subscriptions.removeAll()
    }
    private func refreshPolicy() {
        guard completion != nil, !closed else { return } // Synthetic providers supply their own admission.
        let process = ProcessInfo.processInfo
        let paused = pressure || process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
        owners.forEach { $0.model?.setPolicyPaused(paused) }
    }
}
