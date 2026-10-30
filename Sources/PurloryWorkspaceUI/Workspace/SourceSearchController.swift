import Combine
import Foundation

struct SourceSearchInput: Sendable {
    let query: String
    let project: WritingProject
    let origin: ProjectRuntimeIdentity
    let cursor: Int
    let scope: SourceSearchScope
}

/// One explicit search surface, fenced by both runtime ownership and query sequence.
@MainActor
final class SourceSearchController: ObservableObject {
    typealias Builder = @Sendable (SourceSearchInput) async throws -> [SourceSearchHit]
    @Published private(set) var hits: [SourceSearchHit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isInvalidated = false
    private(set) var preparedInput: SourceSearchInput?
    private(set) var errorMessage: String?
    var didChange: (() -> Void)?
    var didInvalidate: (() -> Void)?
    private let session: ProjectSession
    private let origin: ProjectRuntimeIdentity
    private let cursor: Int
    private let delay: Duration
    private let build: Builder
    private var ticket = 0
    private var task: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(session: ProjectSession, origin: ProjectRuntimeIdentity, cursor: Int,
         delay: Duration = .milliseconds(120), build: @escaping Builder = { input in
             try SourceSearch.results(query: input.query, in: input.project,
                 origin: input.origin.key.documentID, cursor: input.cursor, scope: input.scope)
         }) {
        self.session = session; self.origin = origin; self.cursor = cursor
        self.delay = delay; self.build = build
        session.$runtimeIdentity.dropFirst().sink { [weak self] identity in
            if identity != origin { self?.invalidate() }
        }.store(in: &subscriptions)
        session.$isTransitioning.dropFirst().sink { [weak self] transitioning in
            if transitioning { self?.invalidate() }
        }.store(in: &subscriptions)
    }

    func search(query raw: String, scope: SourceSearchScope) {
        cancelRequest()
        guard !isInvalidated, session.runtimeIdentity == origin, session.isEditorEditable,
            let project = session.activeProject else { invalidate(); return }
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { didChange?(); return }
        guard query.utf16.count <= 500 else {
            errorMessage = "검색어를 조금 줄여 주세요."; didChange?(); return
        }
        let input = SourceSearchInput(query: query, project: project, origin: origin, cursor: cursor, scope: scope)
        let current = ticket, delay = delay, build = build
        isSearching = true; didChange?()
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) { try await build(input) }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.ticket == current, !self.isInvalidated,
                    self.session.runtimeIdentity == input.origin else { return }
                self.task = nil; self.isSearching = false; self.preparedInput = input; self.hits = result
                self.didChange?()
            } catch {
                guard let self, self.ticket == current, !self.isInvalidated else { return }
                self.task = nil; self.isSearching = false
                if !(error is CancellationError) { self.errorMessage = "검색할 수 없어요. 다시 시도해 주세요." }
                self.didChange?()
            }
        }
    }

    func dismiss() { invalidate(); subscriptions.removeAll() }

    private func cancelRequest() {
        ticket += 1; task?.cancel(); task = nil
        hits = []; preparedInput = nil; isSearching = false; errorMessage = nil
    }

    private func invalidate() {
        guard !isInvalidated else { return }
        cancelRequest(); isInvalidated = true
        didChange?(); didInvalidate?()
    }
}
