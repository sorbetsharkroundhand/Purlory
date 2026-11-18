import AppKit
import os

/// In-memory, opt-in measurements. No manuscript or input strings are retained.
struct EditorInputTrace: Codable {
    struct Sample: Codable {
        var sequence: Int
        var kind: String
        var timestamp: Double
        var id: Int
        var operationID: Int?
        var parentID: Int?
        var revision: Int
        var eventTimestamp: Double?
        var eventTimestampComparable: Bool?
        var location: Int?
        var length: Int?
        var delta: Int?
        var editedCharacters: Bool?
        var rect: [Double]?
        var mainThread: Bool
        var composing: Bool
    }
    let samples: [Sample]
    let droppedSamples: Int
    let finalRevision: Int
}

/// One recorder belongs to one view and one burst. A nil attachment performs no recording work.
@MainActor
final class EditorInputTraceRecorder {
    enum OperationKind: String { case keyDown, insertText, setMarkedText, unmarkText, deleteBackward, newline, cursor, selectionReplacement, paste }
    enum Phase: String { case coordinator, serialization, binding, projection, forwarding, renderRefresh }
    struct OperationToken { let id: Int; fileprivate let owner: UUID }
    struct PhaseToken { let id: Int; fileprivate let owner: UUID }
    struct DrawToken { let id: Int; let revision: Int; fileprivate let owner: UUID }
    private let owner = UUID()
    private let capacity: Int
    private let clock: () -> Double
    private let signposter: OSSignposter?
    private var intervals: [Int: OSSignpostIntervalState] = [:]
    private var samples: [EditorInputTrace.Sample] = []
    private var operations: [(id: Int, composing: Bool)] = []
    private var phases: [Int: Phase] = [:]
    private var draws: Set<Int> = []
    private var nextID = 0
    private var revision = 0
    private var dropped = 0
    private var finished: EditorInputTrace?

    init(capacity: Int = 100_000, signposts: Bool = false,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(0, capacity)
        self.clock = clock
        signposter = signposts ? OSSignposter(subsystem: "com.purlory.input-benchmark", category: "EditorInput") : nil
        samples.reserveCapacity(min(self.capacity, 4096))
    }

    private func identifier() -> Int { nextID += 1; return nextID }
    private func beginInterval(_ id: Int) {
        if let signposter {
            intervals[id] = signposter.beginInterval("EditorInput", id: signposter.makeSignpostID(), "correlation=\(id, privacy: .public)")
        }
    }
    private func endInterval(_ id: Int) {
        if let state = intervals.removeValue(forKey: id) { signposter?.endInterval("EditorInput", state) }
    }
    private func append(_ kind: String, id: Int, parent: Int? = nil, capturedRevision: Int? = nil,
                        eventTimestamp: Double? = nil, range: NSRange? = nil, delta: Int? = nil,
                        editedCharacters: Bool? = nil, rect: NSRect? = nil, composing: Bool? = nil) {
        guard finished == nil else { return }
        guard samples.count < capacity else { dropped += 1; return }
        let now = clock()
        // Preserve finite original uptime seconds separately from mapping validity. JSON cannot
        // encode non-finite values, but their rejected mapping remains explicit. Synthetic calls
        // never pass a native event timestamp or manufacture a queue-delay measurement.
        let rawEvent = eventTimestamp.flatMap { $0.isFinite ? $0 : nil }
        let comparable = eventTimestamp.map { $0.isFinite && $0 >= 0 && $0 <= now }
        samples.append(.init(sequence: samples.count, kind: kind, timestamp: now, id: id,
            operationID: operations.last?.id, parentID: parent, revision: capturedRevision ?? revision,
            eventTimestamp: rawEvent, eventTimestampComparable: comparable,
            location: range?.location, length: range?.length, delta: delta,
            editedCharacters: editedCharacters,
            rect: rect.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)] },
            mainThread: Thread.isMainThread, composing: composing ?? operations.last?.composing ?? false))
    }

    func beginOperation(kind: OperationKind, eventTimestamp: Double? = nil, composing: Bool = false) -> OperationToken {
        let token = OperationToken(id: identifier(), owner: owner)
        guard finished == nil else { return token }
        let parent = operations.last?.id
        operations.append((token.id, composing))
        append("operation.begin.\(kind.rawValue)", id: token.id, parent: parent,
               eventTimestamp: eventTimestamp, composing: composing)
        beginInterval(token.id)
        return token
    }
    func endOperation(_ token: OperationToken) {
        guard finished == nil, token.owner == owner,
              let index = operations.firstIndex(where: { $0.id == token.id }) else { return }
        append("operation.end", id: token.id)
        operations.remove(at: index)
        endInterval(token.id)
    }
    func storageProcessed(range: NSRange, delta: Int, editedCharacters: Bool, composing: Bool = false) {
        guard finished == nil else { return }
        if editedCharacters { revision += 1 }
        append("storage", id: identifier(), range: range, delta: delta,
               editedCharacters: editedCharacters, composing: composing)
    }
    func beginPhase(_ phase: Phase) -> PhaseToken {
        let token = PhaseToken(id: identifier(), owner: owner)
        guard finished == nil else { return token }
        phases[token.id] = phase
        append("phase.begin.\(phase.rawValue)", id: token.id)
        beginInterval(token.id)
        return token
    }
    func endPhase(_ token: PhaseToken) {
        guard finished == nil, token.owner == owner, let phase = phases.removeValue(forKey: token.id) else { return }
        append("phase.end.\(phase.rawValue)", id: token.id)
        endInterval(token.id)
    }
    func drawBegan(_ rect: NSRect) -> DrawToken {
        let token = DrawToken(id: identifier(), revision: revision, owner: owner)
        guard finished == nil else { return token }
        draws.insert(token.id)
        append("draw.begin", id: token.id, capturedRevision: token.revision, rect: rect)
        beginInterval(token.id)
        return token
    }
    func drawEnded(_ token: DrawToken) {
        guard finished == nil, token.owner == owner, draws.remove(token.id) != nil else { return }
        append("draw.end", id: token.id, capturedRevision: token.revision)
        endInterval(token.id)
    }
    func finish() -> EditorInputTrace {
        if let finished { return finished }
        let snapshot = EditorInputTrace(samples: samples, droppedSamples: dropped, finalRevision: revision)
        finished = snapshot
        for id in Array(intervals.keys) { endInterval(id) }
        operations.removeAll(); phases.removeAll(); draws.removeAll()
        return snapshot
    }
}
