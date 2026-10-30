import CryptoKit
import Foundation

/// A scoped request for evidence-bounded review, never a verdict or writer canon.
public struct ContinuityCandidate: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case deadSpeaker, honorificBreak, knowledgeLeak, locationOverlap, ageArithmetic, objectReappearance, relationshipIdentity }
    public let id: String
    public let scope: StoryMemoryScope
    public let sourceRevision: String
    public let kind: Kind
    public let subjectID: UUID
    public let evidence: [EvidenceAnchor]
    public let factIDs: [String]
    public let requiresJudging: Bool
    public var explanation: String {
        switch kind {
        case .deadSpeaker: "사망 기록 뒤의 발화인지 원문을 확인해 보세요."
        case .honorificBreak: "상대에게 쓰던 말투가 바뀌었는지 확인해 보세요."
        case .knowledgeLeak: "같은 시점에 아는 기록과 모르는 기록이 함께 있어요."
        case .locationOverlap: "같은 시점에 다른 위치가 기록되어 있어요."
        case .ageArithmetic: "기록된 연도와 만 나이의 관계를 확인해 보세요."
        case .objectReappearance: "사라지거나 파괴된 물건의 복구 과정을 확인해 보세요."
        case .relationshipIdentity: "같은 시점의 관계나 정체 기록을 확인해 보세요."
        }
    }
    private init(id: String, scope: StoryMemoryScope, sourceRevision: String, kind: Kind, subjectID: UUID, evidence: [EvidenceAnchor], factIDs: [String], requiresJudging: Bool) {
        self.id = id; self.scope = scope; self.sourceRevision = sourceRevision; self.kind = kind; self.subjectID = subjectID; self.evidence = evidence; self.factIDs = factIDs; self.requiresJudging = requiresJudging
    }

    /// Snapshot preparation already verified originals, registrations and writer authority.
    public static func prepare(snapshot: StoryKnowledgeSnapshot, before: Int) -> [Self] {
        guard !Task.isCancelled, (0...snapshot.sourceLength).contains(before) else { return [] }
        let observations = snapshot.observations(before: before)
        guard observations.count <= 8192 else { return [] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func encoded<T: Encodable>(_ value: T) -> String {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let scopeKey = encoded(snapshot.scope)
        func logical(_ fact: StoryFact) -> String { encoded([encoded(fact.content), encoded(fact.storyInterval)]) }
        var output: [Self] = [], comparisons = 0
        func append(_ kind: Kind, subject: UUID, _ a: StoryFact, _ b: StoryFact) {
            let key = encoded([scopeKey, kind.rawValue, subject.uuidString] + [logical(a), logical(b)].sorted())
            let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            guard !output.contains(where: { $0.id == id }) else { return }
            let pair: [StoryFact] = [a, b].sorted { (left: StoryFact, right: StoryFact) -> Bool in
                let leftOffset = left.evidence.utf16Hint ?? left.discourseRange.lowerBound
                let rightOffset = right.evidence.utf16Hint ?? right.discourseRange.lowerBound
                if leftOffset != rightOffset { return leftOffset < rightOffset }
                return left.derivedID < right.derivedID
            }
            output.append(.init(id: id, scope: snapshot.scope, sourceRevision: snapshot.sourceRevision,
                kind: kind, subjectID: subject, evidence: pair.map(\.evidence), factIDs: pair.map(\.derivedID), requiresJudging: true))
            output.sort(by: ordered)
            if output.count > 128 { output.removeLast() }
        }
        let groups = Dictionary(grouping: observations.compactMap { fact -> (String, StoryFact)? in
            guard let slot = slot(fact.content) else { return nil }
            return (slot, fact)
        }, by: { $0.0 })
        for key in groups.keys.sorted() {
            guard !Task.isCancelled else { return [] }
            let values = (groups[key] ?? []).map { $0.1 }
            if key.hasPrefix("object:") {
                // Unknown time cannot be silently omitted from a purported transition chain.
                guard values.allSatisfy({ start($0.storyInterval) != nil }) else { continue }
                let ordered = values.sorted {
                    let a = start($0.storyInterval)!, b = start($1.storyInterval)!
                    if a.timelineID != b.timelineID { return a.timelineID.uuidString < b.timelineID.uuidString }
                    if a.tick != b.tick { return a.tick < b.tick }
                    return $0.discourseRange.upperBound < $1.discourseRange.upperBound
                }
                var previous: StoryFact?
                for fact in ordered {
                    guard !Task.isCancelled else { return [] }
                    guard authoritative(fact) else { previous = nil; continue }
                    if let prior = previous, start(prior.storyInterval)?.timelineID == start(fact.storyInterval)?.timelineID,
                       case .objectState(let a) = prior.content, case .objectState(let b) = fact.content,
                       ["파괴됨", "소실"].contains(a.value), ["온전함", "존재"].contains(b.value) {
                        append(.objectReappearance, subject: a.objectID, prior, fact)
                    }
                    previous = fact
                }
                continue
            }
            var seen: Set<String> = []
            let unique = values.filter { authoritative($0) && seen.insert(logical($0)).inserted }
            for index in unique.indices {
                for other in unique.indices where other > index {
                    comparisons += 1
                    // An over-budget pass publishes nothing rather than an incomplete claim set.
                    guard !Task.isCancelled, comparisons <= 65536 else { return [] }
                    let a = unique[index], b = unique[other]
                    if case .characterAge(let x) = a.content, case .characterAge(let y) = b.content {
                        if let left = birthYears(x), let right = birthYears(y), !left.overlaps(right) {
                            append(.ageArithmetic, subject: x.characterID, a, b)
                        }
                        continue
                    }
                    guard a.storyInterval.overlap(with: b.storyInterval) == .overlapping else { continue }
                    switch (a.content, b.content) {
                    case (.characterKnowledge(let x), .characterKnowledge(let y)):
                        if (x.stance == .unaware && y.stance == .knows) || (x.stance == .knows && y.stance == .unaware) {
                            append(.knowledgeLeak, subject: x.characterID, a, b)
                        }
                    case (.characterState(let x), .characterState(let y)):
                        if x.value != y.value { append(.locationOverlap, subject: x.characterID, a, b) }
                    case (.relationship(let x), .relationship(let y)):
                        if opposing(x.value, y.value) { append(.relationshipIdentity, subject: x.fromID, a, b) }
                    default: break
                    }
                }
            }
        }
        return Task.isCancelled ? [] : output
    }

    /// Full captured-document preparation, called only by the background snapshot owner.
    public static func prepare(snapshot: KnowledgeSnapshot, warnings: [ConsistencyWarning], scope: StoryMemoryScope, source: String) -> [Self] {
        guard !Task.isCancelled, warnings.count <= 8192, snapshot.entryID == scope.documentID.rawValue,
              DocumentOutline.parse(source) == snapshot.outline,
              snapshot.storyKnowledge != nil || snapshot.storyMemory != nil,
              snapshot.storyKnowledge.map({ $0.scope == scope }) != false,
              snapshot.storyMemory.map({ $0.scope == scope }) != false else { return [] }
        let revision = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        guard snapshot.storyKnowledge.map({ $0.sourceRevision == revision }) != false else { return [] }
        let legacyRevision = DocumentOutline.stableHash(source), length = source.utf16.count
        var result = snapshot.storyKnowledge.map { prepare(snapshot: $0, before: length) } ?? []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for warning in warnings {
            guard !Task.isCancelled else { return [] }
            guard warning.sourceRevision == legacyRevision, warning.evidence.count >= 2,
                  warning.evidence.allSatisfy({ anchor in
                      guard anchor.documentID == scope.documentID, let hint = anchor.utf16Hint,
                            hint >= 0, hint <= length, anchor.quote.utf16.count <= length - hint else { return false }
                      return SourceAnchor.uniqueOriginalRange(for: anchor.quote, in: source,
                          within: .init(location: hint, length: anchor.quote.utf16.count)) != nil
                  }) else { continue }
            let kind: Kind = warning.kind == .deadSpeaker ? .deadSpeaker : .honorificBreak
            let scopeKey = (try? encoder.encode(scope)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let identity = [scopeKey, kind.rawValue, warning.characterID.uuidString, warning.message] + warning.evidence.map(\.quote)
            guard let data = try? encoder.encode(identity) else { continue }
            let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard !result.contains(where: { $0.id == id }) else { continue }
            result.append(.init(id: id, scope: scope, sourceRevision: revision, kind: kind,
                subjectID: warning.characterID, evidence: warning.evidence, factIDs: [], requiresJudging: false))
            result.sort(by: ordered)
            if result.count > 128 { result.removeLast() }
        }
        return Task.isCancelled ? [] : result
    }

    private static func birthYears(_ age: CharacterAge) -> ClosedRange<Int64>? {
        let (last, firstOverflow) = age.calendarYear.subtractingReportingOverflow(age.completedYears)
        let (first, secondOverflow) = last.subtractingReportingOverflow(1)
        guard !firstOverflow, !secondOverflow else { return nil }
        return first...last
    }

    private static func authoritative(_ fact: StoryFact) -> Bool {
        if case .writerDecision = fact.origin { return true }
        return fact.confidence.map { $0 >= 0.8 } ?? false
    }
    private static func slot(_ content: StoryFact.Content) -> String? {
        switch content {
        case .characterAge(let x): "age:\(x.characterID):\(x.calendarID)"
        case .characterKnowledge(let x): "knowledge:\(x.characterID):\(x.fact)"
        case .characterState(let x) where x.field == .location: "location:\(x.characterID)"
        case .relationship(let x): "relationship:\(x.fromID):\(x.toID)"
        case .objectState(let x) where x.field == .condition: "object:\(x.objectID)"
        default: nil
        }
    }
    private static func start(_ interval: StoryInterval) -> StoryInstant? {
        switch interval {
        case .unknown: nil
        case .point(let instant): instant
        case .range(let start, _): start
        }
    }
    private static func opposing(_ a: String, _ b: String) -> Bool {
        [("배우자", "배우자 아님"), ("친부", "친부 아님"), ("친모", "친모 아님"), ("동일인", "다른 인물")].contains {
            ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a)
        }
    }
    private static func ordered(_ a: Self, _ b: Self) -> Bool {
        let left = a.evidence.last?.utf16Hint ?? 0, right = b.evidence.last?.utf16Hint ?? 0
        return left == right ? a.id < b.id : left < right
    }
}
