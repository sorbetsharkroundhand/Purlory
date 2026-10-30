import Combine
import Foundation

/// Pure presentation gate shared by the docked view and future Review consumers.
public enum LivingMarginPolicy {
    public static let minimumVisibleConfidence = 0.7
    public static let maximumVisibleInsights = 20

    public static func supports(_ kind: MarginInsight.Kind, in mode: WritingMode) -> Bool {
        switch mode {
        case .fiction:
            true
        case .general:
            switch kind {
            case .suggestion, .writingQuality, .generalReview:
                true
            case .continuity, .openThread, .sceneContext:
                false
            }
        }
    }

    static func hasEquivalentContent(_ lhs: MarginInsight, _ rhs: MarginInsight) -> Bool {
        ContentKey(insight: lhs) == ContentKey(insight: rhs)
    }

    public static func present(
        _ insights: [MarginInsight],
        mode: WritingMode,
        dismissing dismissedIDs: Set<String> = []
    ) -> [MarginInsight] {
        let eligible = insights.enumerated().compactMap { index, insight -> Candidate? in
            guard !dismissedIDs.contains(insight.id),
                supports(insight.kind, in: mode),
                !insight.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !insight.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !insight.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                confidenceAllowsPresentation(insight.confidence),
                insight.kind != .continuity || !insight.evidence.isEmpty
            else { return nil }
            return Candidate(insight: insight, originalIndex: index)
        }

        let byID = deduplicated(eligible, key: { $0.insight.id })
        let byContent = deduplicated(byID, key: { ContentKey(insight: $0.insight) })

        return byContent.sorted { lhs, rhs in
            let lhsPriority = priority(of: lhs.insight.kind)
            let rhsPriority = priority(of: rhs.insight.kind)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.originalIndex < rhs.originalIndex
        }
        .prefix(maximumVisibleInsights)
        .map(\.insight)
    }

    private static func confidenceAllowsPresentation(_ confidence: Double?) -> Bool {
        guard let confidence else { return true }
        return confidence.isFinite && confidence >= minimumVisibleConfidence
    }

    private static func priority(of kind: MarginInsight.Kind) -> Int {
        switch kind {
        case .continuity: 0
        case .writingQuality: 1
        case .openThread: 2
        case .sceneContext: 3
        case .suggestion: 4
        case .generalReview: 5
        }
    }

    private static func deduplicated<Key: Hashable>(
        _ candidates: [Candidate],
        key: (Candidate) -> Key
    ) -> [Candidate] {
        var result: [Key: Candidate] = [:]
        for candidate in candidates {
            let candidateKey = key(candidate)
            guard let existing = result[candidateKey] else {
                result[candidateKey] = candidate
                continue
            }
            result[candidateKey] = preferred(candidate, over: existing)
        }
        return result.values.sorted { $0.originalIndex < $1.originalIndex }
    }

    private static func preferred(_ candidate: Candidate, over existing: Candidate) -> Candidate {
        let candidateConfidence = candidate.insight.confidence ?? 1
        let existingConfidence = existing.insight.confidence ?? 1
        var selected = candidateConfidence > existingConfidence ? candidate : existing
        selected.insight.evidence = stableUnique(
            existing.insight.evidence + candidate.insight.evidence,
            key: { $0 })
        selected.insight.actions = stableUnique(
            existing.insight.actions + candidate.insight.actions,
            key: { $0.id })
        selected.originalIndex = min(candidate.originalIndex, existing.originalIndex)
        return selected
    }

    private static func stableUnique<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key
    ) -> [Value] {
        var seen: Set<Key> = []
        return values.filter { seen.insert(key($0)).inserted }
    }

    private struct Candidate {
        var insight: MarginInsight
        var originalIndex: Int
    }

    private struct ContentKey: Hashable {
        var kind: MarginInsight.Kind
        var title: String
        var message: String
        var writingOccurrence: EvidenceAnchor?

        init(insight: MarginInsight) {
            kind = insight.kind
            title = Self.normalized(insight.title)
            message = Self.normalized(insight.message)
            writingOccurrence = insight.kind == .writingQuality ? insight.evidence.first : nil
        }

        private static func normalized(_ value: String) -> String {
            value.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .lowercased()
        }
    }
}

/// App-lifetime, presentation-only state. Intelligence producers replace values here;
/// the model performs no scanning, inference, storage, or durable user-data mutation.
@MainActor
public final class LivingMarginModel: ObservableObject {
    @Published public private(set) var insights: [MarginInsight]
    @Published public private(set) var dismissedIDs: Set<String>
    private var otherProducerInsights: [MarginInsight]
    private var writingQualityInsights: [MarginInsight] = []

    public init(
        insights: [MarginInsight] = [],
        dismissedIDs: Set<String> = []
    ) {
        self.insights = insights
        self.otherProducerInsights = insights
        self.dismissedIDs = dismissedIDs
    }

    public func replace(with insights: [MarginInsight]) {
        otherProducerInsights = insights
        self.insights = otherProducerInsights + writingQualityInsights
    }

    public func replace(writingQuality insights: [MarginInsight]) {
        writingQualityInsights = insights
        self.insights = otherProducerInsights + writingQualityInsights
    }

    public func dismiss(_ insightID: String) {
        guard let dismissedInsight = insights.first(where: { $0.id == insightID }) else {
            dismissedIDs.insert(insightID)
            return
        }
        let groupedIDs = insights.lazy
            .filter { LivingMarginPolicy.hasEquivalentContent($0, dismissedInsight) }
            .map(\.id)
        dismissedIDs.formUnion(groupedIDs)
    }

    public func restoreDismissed() {
        dismissedIDs.removeAll()
    }

    public func visibleInsights(for mode: WritingMode) -> [MarginInsight] {
        LivingMarginPolicy.present(insights, mode: mode, dismissing: dismissedIDs)
    }
}
