import Combine
import Foundation

/// Explicit owner-scoped answers. Presentation consumes only validated records, never raw model prose.
@MainActor
final class AskPurloryController: ObservableObject {
    enum Status: Equatable { case idle, preparing, answering, complete, insufficient, cancelled, unavailable, paused, failed, invalidated }
    typealias Builder = @Sendable (SourceSearchInput) async throws -> AskEvidencePacket
    typealias Generator = @MainActor (AskEvidencePacket, String) throws -> AskAnswerGeneration
    @Published private(set) var status: Status = .idle
    @Published private(set) var blocks: [AskAnswerBlock] = []
    @Published private(set) var packet: AskEvidencePacket?
    private(set) var errorMessage: String?
    var didChange: (() -> Void)?
    private let session: ProjectSession
    private let origin: ProjectRuntimeIdentity
    private let query: String
    private let cursor: Int
    private let scope: SourceSearchScope
    private let build: Builder
    private let generate: Generator
    private var modelAvailable: Bool
    private var foregroundBusy = false, policyPaused = false, invalidated = false
    private var ticket = 0
    private var task: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    var isRunning: Bool { status == .preparing || status == .answering }
    var canAsk: Bool { !invalidated && modelAvailable && !foregroundBusy && !policyPaused && session.runtimeIdentity == origin && session.isEditorEditable }

    init(session: ProjectSession, input: SourceSearchInput, modelAvailable: Bool,
         build: @escaping Builder = { try AskEvidencePacket.prepare($0) }, generate: @escaping Generator) {
        self.session = session; origin = input.origin; query = input.query; cursor = input.cursor; scope = input.scope
        self.modelAvailable = modelAvailable; self.build = build; self.generate = generate
        session.$runtimeIdentity.dropFirst().sink { [weak self] value in
            if let self, value != self.origin { self.invalidate() }
        }.store(in: &subscriptions)
        session.$activeProject.dropFirst().sink { [weak self] _ in self?.invalidate() }.store(in: &subscriptions)
        session.$isTransitioning.dropFirst().sink { [weak self] value in if value { self?.invalidate() } }.store(in: &subscriptions)
    }

    func ask(question raw: String) {
        guard !invalidated, session.runtimeIdentity == origin, session.isEditorEditable,
              let project = session.activeProject else { invalidate(); return }
        guard modelAvailable else { retire(as: .unavailable); return }
        guard !foregroundBusy, !policyPaused else { retire(as: .paused); return }
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf16.count <= 500 else {
            errorMessage = "질문을 조금 줄여 주세요."; didChange?(); return
        }
        retire(as: .preparing, clear: true)
        let current = ticket, build = build
        let input = SourceSearchInput(query: query, project: project, origin: origin, cursor: cursor, scope: scope)
        task = Task { [weak self] in
            var decoder: AskAnswerDecoder?
            var generation: AskAnswerGeneration?
            do {
                let worker = Task.detached(priority: .utility) { try await build(input) }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.owns(current), prepared.origin == self.origin else { return }
                self.packet = prepared; decoder = AskAnswerDecoder(packet: prepared)
                generation = try self.generate(prepared, question)
                self.status = .answering; self.didChange?()
                for try await chunk in generation!.stream {
                    try Task.checkCancellation()
                    guard self.owns(current) else { throw CancellationError() }
                    _ = try decoder!.append(chunk)
                    self.blocks = decoder!.blocks; self.didChange?()
                    if decoder!.isInsufficient || decoder!.blocks.count == 20 { break }
                }
                if let generation { await generation.cancelAndDrain() }
                try Task.checkCancellation()
                guard self.owns(current) else { return }
                _ = try decoder!.finish()
                self.blocks = decoder!.blocks; self.task = nil
                self.status = decoder!.isInsufficient ? .insufficient : .complete
                self.didChange?()
            } catch {
                if let generation { await generation.cancelAndDrain() }
                guard let self, self.owns(current) else { return }
                self.blocks = decoder?.blocks ?? []; self.task = nil
                self.status = error is CancellationError ? .cancelled : .failed
                self.errorMessage = error is CancellationError ? nil : "답변을 확인할 수 없어요. 질문이나 검색 범위를 바꿔 다시 시도해 주세요."
                self.didChange?()
            }
        }
        didChange?()
    }

    func cancel() { retire(as: .cancelled) }
    func setForegroundBusy(_ value: Bool) { foregroundBusy = value; if value, !invalidated { retire(as: .paused) } else { didChange?() } }
    func setPolicyPaused(_ value: Bool) { policyPaused = value; if value, !invalidated { retire(as: .paused) } else { didChange?() } }
    func setModelAvailable(_ value: Bool) { modelAvailable = value; if !value { retire(as: .unavailable) } else { didChange?() } }
    func dismiss() { invalidate(); subscriptions.removeAll(); didChange = nil }
    private func owns(_ value: Int) -> Bool { !invalidated && ticket == value && session.runtimeIdentity == origin && session.isEditorEditable }
    private func retire(as status: Status, clear: Bool = false) {
        ticket += 1; task?.cancel(); task = nil
        if clear { blocks = []; packet = nil }
        self.status = status; errorMessage = nil; didChange?()
    }
    private func invalidate() {
        guard !invalidated else { return }
        invalidated = true; retire(as: .invalidated, clear: true)
    }
}
