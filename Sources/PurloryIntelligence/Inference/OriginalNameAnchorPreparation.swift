import Combine
import Foundation

/// Optional source preparation has independent ownership from model/indexing work.
@MainActor
package final class OriginalNameAnchorPreparation {
    package struct Request: Sendable {
        let body: String
        let documentID: UUID
        let scope: StoryMemoryScope
        let runtimeIdentity: ProjectRuntimeIdentity?
        let characters: [CharacterCard]
    }
    package typealias Builder = @Sendable (Request, OriginalNameAnchorIndex?) async throws -> OriginalNameAnchorIndex
    @Published package private(set) var index: OriginalNameAnchorIndex?
    package private(set) var scope: StoryMemoryScope?
    package private(set) var runtimeIdentity: ProjectRuntimeIdentity?
    private var pending: Request?
    private var memo: OriginalNameAnchorIndex?
    private var memoScope: StoryMemoryScope?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var foregroundBusy = false
    private let delay: Duration
    private let gate: @Sendable () -> Bool
    private let build: Builder

    package init(
        delay: Duration = .milliseconds(200),
        gate: @escaping @Sendable () -> Bool = {
            let process = ProcessInfo.processInfo
            return !process.isLowPowerModeEnabled
                && process.thermalState != .serious && process.thermalState != .critical
        },
        build: @escaping Builder = { request, previous in
            try OriginalNameAnchorIndex.make(body: request.body,
                documentID: request.documentID, characters: request.characters, previous: previous)
        }
    ) {
        self.delay = delay
        self.gate = gate
        self.build = build
    }

    package func prepare(
        body: String, documentID: UUID, scope: StoryMemoryScope,
        runtimeIdentity: ProjectRuntimeIdentity?, characters: [CharacterCard]
    ) {
        cancel()
        index = nil
        self.scope = nil
        self.runtimeIdentity = nil
        if memoScope != scope { memo = nil }
        pending = Request(body: body, documentID: documentID, scope: scope,
            runtimeIdentity: runtimeIdentity, characters: characters)
        startIfAllowed()
    }

    package func setForegroundBusy(_ busy: Bool) {
        foregroundBusy = busy
        if busy { cancel() } else { startIfAllowed() }
    }

    package func shutdown() {
        cancel()
        pending = nil
        index = nil
        scope = nil
        runtimeIdentity = nil
        memo = nil
        memoScope = nil
        foregroundBusy = false
    }

    private func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func startIfAllowed() {
        guard task == nil, !foregroundBusy, gate(), let request = pending else { return }
        let ticket = generation, previous = memoScope == request.scope ? memo : nil
        let delay = delay, build = build, gate = gate
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                guard gate() else {
                    await self?.finish(ticket: ticket, request: request, result: nil)
                    return
                }
                let result = try await build(request, previous)
                await self?.finish(ticket: ticket, request: request, result: result)
            } catch {
                await self?.finish(ticket: ticket, request: request, result: nil)
            }
        }
    }

    private func finish(ticket: Int, request: Request, result: OriginalNameAnchorIndex?) {
        guard ticket == generation, !foregroundBusy else { return }
        task = nil
        guard let result, result.documentID == request.documentID, gate() else { return }
        pending = nil
        memo = result
        memoScope = request.scope
        scope = request.scope
        runtimeIdentity = request.runtimeIdentity
        index = result
    }
}
