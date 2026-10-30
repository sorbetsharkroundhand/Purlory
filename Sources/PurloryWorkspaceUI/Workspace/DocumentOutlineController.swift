import Combine
import Foundation

struct PreparedDocumentOutline: Equatable, Sendable {
    let identity: ProjectRuntimeIdentity
    let projection: DocumentOutlineProjection
}

@MainActor
final class DocumentOutlineController: ObservableObject {
    enum Status { case idle, checking, paused, unavailable }
    @Published private(set) var prepared: PreparedDocumentOutline?
    @Published private(set) var currentHeadingID: Int?
    @Published private(set) var status = Status.idle
    private(set) var workTask: Task<Void, Never>?
    private var snapshot: ProjectDocumentSnapshot?
    private var epoch: UInt64 = 0
    private var foregroundBusy = false
    private var policyPaused = false
    private var observations: Set<AnyCancellable> = []
    private let sleep: @Sendable () async throws -> Void
    private let project: @Sendable (ProjectDocumentSnapshot) async throws -> DocumentOutlineProjection
    init(observeEnergy: Bool = true, sleep: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(350))
    }, project: (@Sendable (ProjectDocumentSnapshot) async throws -> DocumentOutlineProjection)? = nil) {
        let worker = DocumentOutlineProjector()
        self.project = project ?? { try await worker.project($0) }; self.sleep = sleep
        if observeEnergy {
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                    Task { @MainActor in self?.refreshEnergyPolicy() }
                }.store(in: &observations)
            }
            refreshEnergyPolicy()
        }
    }
    func update(_ next: ProjectDocumentSnapshot?) {
        guard snapshot?.identity != next?.identity else { return }
        snapshot = next; schedule()
    }
    func setForegroundBusy(_ busy: Bool) {
        guard foregroundBusy != busy else { return }
        foregroundBusy = busy; schedule()
    }
    func setPolicyPaused(_ paused: Bool) {
        guard policyPaused != paused else { return }
        policyPaused = paused; schedule()
    }
    private func refreshEnergyPolicy() {
        let info = ProcessInfo.processInfo
        setPolicyPaused(info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical)
    }
    private func invalidate() {
        epoch &+= 1; workTask?.cancel(); workTask = nil; prepared = nil; currentHeadingID = nil
    }
    private func schedule() {
        invalidate()
        guard let snapshot else { status = .idle; return }
        guard !foregroundBusy, !policyPaused else { status = .paused; return }
        status = .checking
        let owned = epoch, sleep = sleep, project = project
        workTask = Task(priority: .utility) { [weak self] in
            do {
                try await sleep(); try Task.checkCancellation()
                let projection = try await project(snapshot)
                guard let self, !Task.isCancelled, self.epoch == owned,
                      self.snapshot?.identity == snapshot.identity else { return }
                self.prepared = .init(identity: snapshot.identity, projection: projection)
                self.status = .idle; self.workTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.epoch == owned else { return }
                self.status = .unavailable; self.workTask = nil
            }
        }
    }
    func stop() { snapshot = nil; invalidate(); status = .idle }
    func notePosition(_ offset: Int?, identity: ProjectRuntimeIdentity?) {
        let next: Int?
        if let prepared, prepared.identity == identity, let offset, offset >= 0 {
            next = prepared.projection.currentHeading(at: offset)?.id
        } else { next = nil }
        if currentHeadingID != next { currentHeadingID = next }
    }
    func waitForCurrentWork() async { while let task = workTask { await task.value } }
}
