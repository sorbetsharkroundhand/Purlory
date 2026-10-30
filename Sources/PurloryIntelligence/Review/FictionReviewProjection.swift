import Foundation

package struct FictionReviewProjection: Equatable, Sendable {
    package let issues: [ReviewIssue]
    package let counts: [ReviewIssue.Category: Int]
    package let isComplete: Bool
    package static func prepare(_ document: ProjectDocumentSnapshot, snapshot: KnowledgeSnapshot?, snapshotOrigin: ProjectRuntimeIdentity?,
                        candidates: [ContinuityCandidate]) async throws -> Self {
        try Task.checkCancellation()
        func result(_ issues: [ReviewIssue] = [], complete: Bool = true) -> Self {
            .init(issues: issues, counts: Dictionary(grouping: issues, by: \.category).mapValues(\.count), isComplete: complete)
        }
        guard candidates.count <= 8192 else { return result(complete: false) }
        guard let context = ReviewOriginalContext.prepare(document, snapshot: snapshot, origin: snapshotOrigin) else { return result() }
        let snapshot = context.snapshot
        guard snapshot.outline.scenes.count <= 8192, snapshot.canonicalEvents.count <= 8192,
              snapshot.plotThreads.count <= 128, snapshot.plotThreads.reduce(0, { $0 + $1.memberKeys.count }) <= 65536,
              snapshot.segmentsByScene.values.reduce(0, { $0 + $1.count }) <= 8192 else { return result(complete: false) }
        var byID: [String: ReviewIssue] = [:]
        func add(_ issue: ReviewIssue?) {
            guard let issue else { return }
            if let previous = byID[issue.id] {
                let next = issue.evidence.flatMap { [$0.utf16Hint ?? .max, $0.quote.utf16.count] }
                let old = previous.evidence.flatMap { [$0.utf16Hint ?? .max, $0.quote.utf16.count] }
                if next != old {
                    guard next.lexicographicallyPrecedes(old) else { return }
                } else {
                    guard (issue.candidate?.factIDs ?? []).lexicographicallyPrecedes(previous.candidate?.factIDs ?? [],
                        by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) else { return }
                }
            }
            byID[issue.id] = issue
        }
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 32) { await Task.yield(); try Task.checkCancellation() }
            guard candidate.scope == snapshot.storyKnowledge?.scope, candidate.sourceRevision == context.revision else { continue }
            let category = ReviewIssue.category(for: candidate.kind)
            add(.prepare(logicalID: "continuity:" + candidate.id, category: category,
                severity: candidate.requiresJudging ? .note : .review, title: title(category), message: candidate.explanation,
                evidence: candidate.evidence, candidate: candidate, context: context))
        }
        let indices = snapshot.outline.unambiguousSceneIndicesByHash
        let events = Dictionary(uniqueKeysWithValues: snapshot.canonicalEvents.map { ($0.canonicalKey, $0) })
        func original(_ key: String) -> EvidenceAnchor? {
            events[key].flatMap { context.original($0.quote, sceneHash: $0.sceneHash, indices: indices) }
        }
        for thread in snapshot.plotThreads where !thread.isMain && thread.status != .resolved {
            try Task.checkCancellation()
            guard thread.confidence.isFinite, (0.8...1).contains(thread.confidence) || thread.userEdited,
                  let first = thread.memberKeys.first.flatMap(original) else { continue }
            var evidence = [first]
            if let last = thread.memberKeys.last.flatMap(original), last.utf16Hint != first.utf16Hint { evidence.append(last) }
            add(.prepare(logicalID: "thread:" + thread.id, category: .openThreads, title: title(.openThreads),
                message: "‘\(thread.title.prefix(80))’의 \(evidence.count == 1 ? "여는 사건을" : "여는 사건과 마지막 기록을 함께") 확인해 보세요.", evidence: evidence, context: context))
        }
        for edge in snapshot.chronoConflicts {
            try Task.checkCancellation()
            guard let a = original(edge.aKey), let b = original(edge.bKey) else { continue }
            add(.prepare(logicalID: "chronology:" + edge.id, category: .timeline, title: title(.timeline),
                message: "두 사건에 기록된 시간 관계를 함께 확인해 보세요.", evidence: [a, b], context: context))
        }
        var visited = 0
        for hash in snapshot.segmentsByScene.keys.sorted() {
            for segment in snapshot.segmentsByScene[hash] ?? [] {
                visited += 1
                if visited.isMultiple(of: 32) { await Task.yield(); try Task.checkCancellation() }
                guard segment.layer.isTemporalShift, segment.returnState == .uncertain, segment.confidence.isFinite,
                      (0.8...1).contains(segment.confidence), let anchor = context.original(segment.startQuote, sceneHash: hash, indices: indices) else { continue }
                add(.prepare(logicalID: "segment:" + segment.persistentID, category: .structure, title: title(.structure),
                    message: "‘\(segment.layer.rawValue)’ 구간에서 돌아오는 경계를 확인해 보세요.", evidence: [anchor], context: context))
            }
        }
        try Task.checkCancellation()
        let ordered = byID.values.sorted {
            if $0.severity != $1.severity { return $0.severity.rawValue < $1.severity.rawValue }
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
            return $0.id < $1.id
        }
        return result(Array(ordered.prefix(256)), complete: ordered.count <= 256)
    }
    private static func title(_ category: ReviewIssue.Category) -> String {
        switch category {
        case .continuity: "설정 확인"
        case .characters: "인물 기록 확인"
        case .timeline: "시간 관계 확인"
        case .dialogue: "말투 확인"
        case .openThreads: "열린 플롯"
        case .structure: "서술 구간 확인"
        }
    }
}
