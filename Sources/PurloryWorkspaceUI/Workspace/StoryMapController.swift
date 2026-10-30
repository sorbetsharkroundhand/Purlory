import Combine
import Foundation

struct PreparedStoryMap: Equatable, Sendable {
    let identity: ProjectRuntimeIdentity
    let projection: StoryMapProjection
}
struct StoryMapInput: Sendable {
    let document: ProjectDocumentSnapshot
    let knowledge: KnowledgeSnapshot?
    let knowledgeOrigin: ProjectRuntimeIdentity?
    let knowledgeGeneration: Int
    let order: StoryMapProjection.Order
}

@MainActor
final class StoryMapController: ObservableObject {
    enum Status: Equatable { case idle, preparing, paused, unavailable }
    typealias Projector = @Sendable (StoryMapInput) async throws -> StoryMapProjection
    @Published private(set) var prepared: PreparedStoryMap?
    @Published private(set) var visibleRows: [StoryMapProjection.Row] = []
    @Published private(set) var currentSceneID: String?
    @Published private(set) var status: Status = .idle
    @Published private(set) var order: StoryMapProjection.Order = .manuscript
    func setOrder(_ order: StoryMapProjection.Order) {
        guard self.order != order else { return }; self.order = order
        if let old = input {
            input = .init(document: old.document, knowledge: old.knowledge, knowledgeOrigin: old.knowledgeOrigin,
                knowledgeGeneration: old.knowledgeGeneration, order: order)
        }
        schedule()
    }
    private weak var session: ProjectSession?
    private let requiresMapMode: Bool
    private let sleep: @Sendable () async throws -> Void
    private let project: Projector
    private var input: StoryMapInput?
    private var currentKey: ProjectDocumentKey?
    private var threadID: String?, characterID: UUID?
    var selectedThreadID: String? { threadID }
    var selectedCharacterID: UUID? { characterID }
    private var foregroundBusy = false, policyPaused = false, energyPaused = false
    private var epoch: UInt64 = 0
    private var workTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    init(session: ProjectSession, requiresMapMode: Bool = true, observeEnergy: Bool = true, sleep: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(350))
    }, project: Projector? = nil) {
        self.session = session; self.requiresMapMode = requiresMapMode; self.sleep = sleep
        let worker = StoryMapProjector()
        self.project = project ?? { try await worker.project($0) }
        session.$runtimeIdentity.dropFirst().sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
        session.$workspaceMode.dropFirst().sink { [weak self] mode in if mode != .map && self?.requiresMapMode == true { self?.stop() } }.store(in: &subscriptions)
        session.$isTransitioning.dropFirst().sink { [weak self] value in if value { self?.stop() } }.store(in: &subscriptions)
        if observeEnergy {
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                    self?.refreshEnergy()
                }.store(in: &subscriptions)
            }
            refreshEnergy()
        }
    }
    func update(knowledge: KnowledgeSnapshot? = nil, knowledgeOrigin: ProjectRuntimeIdentity? = nil, generation: Int = 0) {
        guard let session, (!requiresMapMode || session.workspaceMode == .map), session.isEditorEditable,
              let document = session.selectedDocumentSnapshot, document.mode == .fiction, document.kind == .manuscript else { stop(); return }
        if input?.document.identity == document.identity, input?.knowledgeOrigin == knowledgeOrigin,
           input?.knowledgeGeneration == generation, (input?.knowledge == nil) == (knowledge == nil) { return }
        if currentKey != document.identity.key { threadID = nil; characterID = nil; currentKey = document.identity.key }
        input = .init(document: document, knowledge: knowledge, knowledgeOrigin: knowledgeOrigin, knowledgeGeneration: generation, order: order)
        schedule()
    }
    func filter(threadID: String?, characterID: UUID?) {
        self.threadID = threadID; self.characterID = characterID
        visibleRows = prepared?.projection.filtered(threadID: threadID, characterID: characterID) ?? []
    }
    func notePosition(_ offset: Int?, identity: ProjectRuntimeIdentity?) {
        let next = prepared.flatMap { value in
            value.identity == identity ? offset.flatMap { value.projection.currentScene(at: $0)?.id } : nil
        }
        if currentSceneID != next { currentSceneID = next }
    }
    func setForegroundBusy(_ busy: Bool) {
        guard foregroundBusy != busy else { return }; foregroundBusy = busy; schedule()
    }
    func setPolicyPaused(_ paused: Bool) {
        guard policyPaused != paused else { return }; policyPaused = paused; schedule()
    }
    private func refreshEnergy() {
        let process = ProcessInfo.processInfo
        let paused = process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
        guard energyPaused != paused else { return }; energyPaused = paused; schedule()
    }
    private func invalidate() {
        epoch &+= 1; workTask?.cancel(); workTask = nil
        prepared = nil; visibleRows = []; currentSceneID = nil
    }
    private func owns(_ input: StoryMapInput) -> Bool {
        session?.runtimeIdentity == input.document.identity && (!requiresMapMode || session?.workspaceMode == .map) && session?.isEditorEditable == true
    }
    private func schedule() {
        invalidate()
        guard let input, owns(input) else { status = .idle; return }
        guard !foregroundBusy, !policyPaused, !energyPaused else { status = .paused; return }
        status = .preparing
        let owned = epoch, sleep = sleep, project = project
        workTask = Task { [weak self] in
            do {
                try await sleep(); try Task.checkCancellation()
                let worker = Task.detached(priority: .utility) { try await project(input) }
                let projection = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.epoch == owned, self.owns(input) else { return }
                self.prepared = .init(identity: input.document.identity, projection: projection)
                self.visibleRows = projection.filtered(threadID: self.threadID, characterID: self.characterID)
                self.workTask = nil; self.status = .idle
            } catch {
                guard let self, !Task.isCancelled, self.epoch == owned else { return }
                self.workTask = nil; self.status = .unavailable
            }
        }
    }
    func stop() { input = nil; invalidate(); status = .idle }
    func waitForCurrentWork() async { while let task = workTask { await task.value } }
}

/// Original-byte memoization stays behind the utility worker, never in a view callback.
actor StoryMapProjector {
    private struct Cached {
        let key: ProjectDocumentKey
        let source: String
        let mode: WritingMode
        let kind: WritingDocument.Kind
        let knowledgeOrigin: ProjectRuntimeIdentity?
        let knowledgeGeneration: Int
        let hasKnowledge: Bool
        let order: StoryMapProjection.Order
        let projection: StoryMapProjection
    }
    private var cache: [Cached] = []
    private(set) var buildCount = 0
    var retainedCount: Int { cache.count }
    func project(_ input: StoryMapInput) async throws -> StoryMapProjection {
        try Task.checkCancellation()
        if let index = cache.firstIndex(where: {
            $0.key == input.document.identity.key && $0.mode == input.document.mode && $0.kind == input.document.kind
                && $0.knowledgeOrigin == input.knowledgeOrigin
                && $0.knowledgeGeneration == input.knowledgeGeneration && $0.hasKnowledge == (input.knowledge != nil)
                && $0.order == input.order && $0.source.utf16.elementsEqual(input.document.body.utf16)
        }) {
            let hit = cache.remove(at: index); cache.append(hit); return hit.projection
        }
        buildCount += 1
        let projection = try await StoryMapProjection.build(input.document, knowledge: input.knowledge, knowledgeOrigin: input.knowledgeOrigin, order: input.order)
        try Task.checkCancellation()
        cache.append(.init(key: input.document.identity.key, source: input.document.body, mode: input.document.mode, kind: input.document.kind, knowledgeOrigin: input.knowledgeOrigin,
            knowledgeGeneration: input.knowledgeGeneration, hasKnowledge: input.knowledge != nil, order: input.order, projection: projection))
        if cache.count > 2 { cache.removeFirst(cache.count - 2) }
        return projection
    }
}
