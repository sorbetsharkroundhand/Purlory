import Foundation
import HuggingFace

/// Prefetch and load share the same revision-pinned, verified installation store.
@MainActor
public final class ModelDownloadManager: ObservableObject {
    public enum State: Equatable, Sendable {
        case notDownloaded, verifying, downloaded
        case downloading(Double)
        case failed(String)
    }
    public static let shared = ModelDownloadManager()
    @Published public private(set) var states: [String: State] = [:]
    private let store: ModelInstallationStore
    private let manifestForID: @Sendable (String) -> ModelInstallManifest?
    private let fileDownload: ModelInstallationStore.Download
    private let startBlock: @Sendable () -> String?
    private let admit: @Sendable (ModelInstallManifest) throws -> Void
    private var tasks: [String: Task<Void, Never>] = [:]
    private var retiring: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]
    private var progressGates: [String: ProgressCoalescer] = [:]

    public convenience init() {
        self.init(store: .shared, manifestForID: { PinnedModelCatalog.manifest(for: $0) },
                  download: Self.transfer, startBlock: Self.currentStartBlock,
                  admit: { try ModelMemoryPolicy.current.requireLoad(manifest: $0) })
    }
    init(store: ModelInstallationStore,
         manifestForID: @Sendable @escaping (String) -> ModelInstallManifest?,
         download: @escaping ModelInstallationStore.Download,
         startBlock: @Sendable @escaping () -> String?,
         admit: @Sendable @escaping (ModelInstallManifest) throws -> Void = { _ in }) {
        self.store = store; self.manifestForID = manifestForID
        self.fileDownload = download; self.startBlock = startBlock; self.admit = admit
    }
    deinit { for task in tasks.values { task.cancel() } }

    /// Verification is cancellable background work, never a synchronous menu scan.
    public func refresh(_ modelIDs: [String]) {
        for id in modelIDs where tasks[id] == nil {
            guard let pin = manifestForID(id) else { states[id] = .failed(ModelInstallError.metadata.localizedDescription); continue }
            if let reason = startBlock() { states[id] = .failed(reason); continue }
            let token = UUID(); tokens[id] = token; states[id] = .verifying
            tasks[id] = Task(priority: .utility) { [weak self, store] in
                let state = await store.state(for: pin)
                guard !Task.isCancelled else { return }
                self?.finish(id, token: token, state: Self.presentation(state))
            }
        }
    }
    public func download(_ id: String) {
        guard tasks[id] == nil else { return }
        guard let pin = manifestForID(id) else { states[id] = .failed(ModelInstallError.metadata.localizedDescription); return }
        if let reason = startBlock() { states[id] = .failed(reason); return }
        do { try admit(pin) } catch { states[id] = .failed(error.localizedDescription); return }
        let token = UUID(), previous = retiring[id]
        tokens[id] = token; states[id] = .downloading(0); progressGates[id] = ProgressCoalescer()
        tasks[id] = Task(priority: .utility) { [weak self, store, fileDownload] in
            do {
                if let previous { await previous.value }
                try Task.checkCancellation()
                _ = try await store.install(pin, download: fileDownload) { [weak self] phase, fraction in
                    Task { @MainActor in self?.note(id, token: token, phase: phase, fraction: fraction) }
                }
                try Task.checkCancellation()
                self?.finish(id, token: token, state: .downloaded)
            } catch is CancellationError {
                self?.finish(id, token: token, state: .notDownloaded)
            } catch {
                self?.finish(id, token: token, state: .failed(error.localizedDescription))
            }
        }
    }
    public func cancel(_ id: String) {
        let previous = tasks.removeValue(forKey: id)
        tokens[id] = nil; progressGates[id] = nil
        previous?.cancel(); states[id] = .notDownloaded
        // A retry waits until this cancellation and its old caller have retired.
        retiring[id] = Task { [store] in
            await store.cancel(id)
            if let previous { await previous.value }
        }
    }
    public func cancelAndWait(_ id: String) async {
        cancel(id)
        await retiring[id]?.value
    }
    private func finish(_ id: String, token: UUID, state: State) {
        guard tokens[id] == token else { return }
        states[id] = state; tasks[id] = nil; tokens[id] = nil; progressGates[id] = nil
    }
    private func note(_ id: String, token: UUID, phase: ModelInstallationStore.State, fraction: Double) {
        guard tokens[id] == token, tasks[id] != nil else { return }
        if phase == .verifying { states[id] = .verifying }
        if phase == .downloading {
            if case .downloading = states[id], !(progressGates[id]?.shouldEmit(fraction) ?? true) { return }
            states[id] = .downloading(fraction)
        }
    }
    private static func presentation(_ state: ModelInstallationStore.State) -> State {
        switch state {
        case .missing, .removing: .notDownloaded
        case .ready: .downloaded
        case .downloading: .downloading(0)
        case .verifying: .verifying
        case .interrupted: .failed("모델 설치가 중단되었습니다. 다시 내려받으세요. 원고 편집은 계속할 수 있습니다.")
        case .failed(let reason): .failed(reason)
        }
    }
    package nonisolated static func transfer(_ manifest: ModelInstallManifest, _ file: ModelInstallManifest.File, _ destination: URL) async throws {
        if let reason = currentStartBlock() { throw TransferBlocked(reason: reason) }
        let parts = manifest.id.split(separator: "/")
        let repo = Repo.ID(namespace: String(parts[0]), name: String(parts[1]))
        // Isolated owned files: never trust or delete a shared Hub cache entry.
        _ = try await HubClient(cache: nil).downloadFile(at: file.path, from: repo, to: destination,
                                                       kind: .model, revision: manifest.revision)
    }
    private struct TransferBlocked: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    nonisolated private static func currentStartBlock() -> String? {
        startBlockReason(thermal: ProcessInfo.processInfo.thermalState, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    nonisolated static func startBlockReason(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> String? {
        switch thermal {
        case .serious, .critical: return "기기가 뜨거워요 — 온도가 내려오면 다시 시도하세요"
        default: break
        }
        if lowPower { return "저전력 모드 중에는 내려받지 않아요 — 충전하거나 해제 후 다시 시도하세요" }
        return nil
    }
}
