import Combine
import Foundation

/// One explicit candidate request. Only a complete grounded proposal can become visible.
@MainActor
final class ContinuityJudgeController: ObservableObject {
    enum Status: Equatable { case idle, preparing, judging, needsReview, quiet, cancelled, unavailable, paused, failed, invalidated }
    typealias Builder = @Sendable (ContinuityCandidate, ProjectDocumentSnapshot) async throws -> JudgeEvidencePacket
    typealias Generator = @MainActor (JudgeEvidencePacket) throws -> AskAnswerGeneration
    @Published private(set) var status: Status = .idle
    @Published private(set) var decision: JudgeDecision?
    @Published private(set) var packet: JudgeEvidencePacket?
    private let session: ProjectSession
    private let origin: ProjectRuntimeIdentity
    private let build: Builder
    private let generate: Generator
    private var modelAvailable: Bool
    private var foregroundBusy = false, policyPaused = false, invalidated = false
    private var ticket = 0
    private var task: Task<Void, Never>?
    private var retiringTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    var isRunning: Bool { status == .preparing || status == .judging }
    var canJudge: Bool { !invalidated && modelAvailable && !foregroundBusy && !policyPaused && session.runtimeIdentity == origin && session.isEditorEditable }

    init(session: ProjectSession, origin: ProjectRuntimeIdentity, modelAvailable: Bool,
         build: @escaping Builder = { try JudgeEvidencePacket.prepare(candidate: $0, document: $1) }, generate: @escaping Generator) {
        self.session = session; self.origin = origin; self.modelAvailable = modelAvailable; self.build = build; self.generate = generate
        session.$runtimeIdentity.dropFirst().sink { [weak self] value in
            if let self, value != self.origin { self.invalidate() }
        }.store(in: &subscriptions)
        session.$activeProject.dropFirst().sink { [weak self] _ in self?.invalidate() }.store(in: &subscriptions)
        session.$isTransitioning.dropFirst().sink { [weak self] value in if value { self?.invalidate() } }.store(in: &subscriptions)
    }
    func judge(candidate: ContinuityCandidate) {
        guard !invalidated, session.runtimeIdentity == origin, session.isEditorEditable,
              let document = session.selectedDocumentSnapshot, document.identity == origin else { invalidate(); return }
        guard modelAvailable else { _ = retire(as: .unavailable); return }
        guard !foregroundBusy, !policyPaused else { _ = retire(as: .paused); return }
        let previous = retire(as: .preparing), current = ticket, build = build
        task = Task { [weak self] in
            var generation: AskAnswerGeneration?
            do {
                // A replacement never hands the actual model to a new supplemental request
                // while the old producer is still draining, even if it ignores cancellation.
                if let previous { await previous.value }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .utility) { try await build(candidate, document) }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.owns(current), prepared.origin == self.origin else { return }
                self.packet = prepared
                generation = try self.generate(prepared)
                self.status = .judging
                var raw = "", count = 0
                for try await chunk in generation!.stream {
                    try Task.checkCancellation()
                    guard self.owns(current), chunk.utf16.count <= 4096 - count else { throw JudgeDecision.Failure.invalidResponse }
                    count += chunk.utf16.count; raw += chunk
                }
                await generation!.cancelAndDrain()
                try Task.checkCancellation()
                guard self.owns(current) else { return }
                let parsed = try JudgeDecision.decode(raw, packet: prepared)
                self.decision = parsed.visibleConflict ? parsed : nil
                self.task = nil; self.retiringTask = nil; self.status = parsed.visibleConflict ? .needsReview : .quiet
            } catch {
                if let generation { await generation.cancelAndDrain() }
                guard let self, self.owns(current) else { return }
                self.decision = nil; self.packet = nil; self.task = nil; self.retiringTask = nil
                self.status = error is CancellationError ? .cancelled : .failed
            }
        }
    }
    func cancel() { _ = retire(as: .cancelled) }
    func setForegroundBusy(_ value: Bool) {
        foregroundBusy = value
        if value, !invalidated { _ = retire(as: .paused) } else { objectWillChange.send() }
    }
    func setPolicyPaused(_ value: Bool) {
        policyPaused = value
        if value, !invalidated { _ = retire(as: .paused) } else { objectWillChange.send() }
    }
    func setModelAvailable(_ value: Bool) {
        modelAvailable = value
        if !value, !invalidated { _ = retire(as: .unavailable) } else { objectWillChange.send() }
    }
    func dismiss() { invalidate(); subscriptions.removeAll() }
    private func owns(_ value: Int) -> Bool { !invalidated && ticket == value && session.runtimeIdentity == origin && session.isEditorEditable }
    private func retire(as status: Status) -> Task<Void, Never>? {
        ticket += 1
        let previous = task ?? retiringTask; previous?.cancel(); task = nil; retiringTask = previous
        decision = nil; packet = nil
        self.status = status
        return previous
    }
    private func invalidate() {
        guard !invalidated else { return }
        invalidated = true; _ = retire(as: .invalidated)
    }
}
