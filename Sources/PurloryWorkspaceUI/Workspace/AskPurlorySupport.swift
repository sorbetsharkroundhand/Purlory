import Combine
import Foundation

@MainActor
final class AskPurlorySupport: ObservableObject {
    @Published private(set) var available: Bool
    private let generate: AskPurloryController.Generator
    private weak var completion: CompletionController?
    private final class Owner { weak var model: AskPurloryController?; init(_ model: AskPurloryController) { self.model = model } }
    private var owners: [Owner] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var pressure = false
    private var selectedModel = ""
    init(available: Bool, generate: @escaping AskPurloryController.Generator) { self.available = available; self.generate = generate }
    static func admits(ready: Bool, authorized: Bool, enabled: Bool, managing: Bool, pressure: Bool, modelID: String) -> Bool {
        ready && authorized && enabled && !managing && !pressure && !modelID.isEmpty
    }

    func observe(_ completion: CompletionController) {
        self.completion = completion
        Publishers.CombineLatest4(completion.$engineState, completion.$isMemoryPressurePaused,
            completion.$isManagingModel, completion.settings.$authorization)
            .combineLatest(Publishers.CombineLatest(completion.settings.$modelID, completion.settings.$autocompleteEnabled))
            .sink { [weak self] values, choice in
                guard let self else { return }
                let (modelID, enabled) = choice
                self.owners.removeAll { $0.model == nil }
                if self.selectedModel != modelID { self.owners.forEach { $0.model?.setModelAvailable(false) } }
                self.selectedModel = modelID; self.pressure = values.1
                let ready = Self.admits(ready: values.0 == .ready, authorized: values.3 == .enabled,
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
    func makeController(session: ProjectSession, input: SourceSearchInput) -> AskPurloryController {
        let model = AskPurloryController(session: session, input: input, modelAvailable: available, generate: generate)
        owners.append(Owner(model))
        completion?.observeForegroundCompletion(owner: model) { [weak model] busy in model?.setForegroundBusy(busy) }
        refreshPolicy(); return model
    }
    private func refreshPolicy() {
        guard completion != nil else { return } // Synthetic providers supply their own admission.
        let process = ProcessInfo.processInfo
        let paused = pressure || process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
        owners.forEach { $0.model?.setPolicyPaused(paused) }
    }
}
