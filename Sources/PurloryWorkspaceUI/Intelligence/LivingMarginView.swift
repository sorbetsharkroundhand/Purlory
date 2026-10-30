import SwiftUI

public struct LivingMarginDescriptor: Equatable, Sendable {
    public var categoryLabel: String
    public var systemImage: String
    public var guidance: String?

    public init(categoryLabel: String, systemImage: String, guidance: String? = nil) {
        self.categoryLabel = categoryLabel
        self.systemImage = systemImage
        self.guidance = guidance
    }
}

/// Text and accessibility semantics are independent of the SwiftUI hierarchy so both
/// General and Fiction renderers keep the same vocabulary and testable VoiceOver output.
public enum LivingMarginRenderer {
    public static func descriptor(for kind: MarginInsight.Kind) -> LivingMarginDescriptor {
        switch kind {
        case .continuity:
            LivingMarginDescriptor(
                categoryLabel: "이어짐 확인",
                systemImage: "arrow.triangle.branch",
                guidance: "원문과 함께 확인해 보세요")
        case .openThread:
            LivingMarginDescriptor(categoryLabel: "열린 실마리", systemImage: "circle.dotted")
        case .sceneContext:
            LivingMarginDescriptor(categoryLabel: "장면 맥락", systemImage: "viewfinder")
        case .suggestion:
            LivingMarginDescriptor(categoryLabel: "제안", systemImage: "lightbulb")
        case .writingQuality:
            LivingMarginDescriptor(
                categoryLabel: "문장 리듬", systemImage: "text.line.first.and.arrowtriangle.forward")
        case .generalReview:
            LivingMarginDescriptor(categoryLabel: "검토", systemImage: "checkmark.circle")
        }
    }

    public static func accessibilitySummary(for insight: MarginInsight) -> String {
        let descriptor = descriptor(for: insight.kind)
        var summary = [descriptor.categoryLabel, insight.title, insight.message]
            .reduce(into: "") { result, part in
                guard !result.isEmpty else {
                    result = part
                    return
                }
                result += result.last.map(isSentenceTerminator) == true ? " " : ". "
                result += part
            }
        if !insight.evidence.isEmpty {
            summary += summary.last.map(isSentenceTerminator) == true ? " " : ". "
            summary += "원문 \(insight.evidence.count)곳"
        }
        return summary
    }

    public static func actionLabels(for insight: MarginInsight) -> [String] {
        let evidenceLabels = insight.evidence.indices.map(evidenceActionLabel)
        let customLabels = insight.actions.compactMap { action -> String? in
            switch action.kind {
            case .jumpToEvidence, .dismiss:
                nil
            case .markIntentional, .showAlternatives, .custom:
                action.title
            }
        }
        return evidenceLabels + customLabels + ["제안 닫기"]
    }

    static func evidenceActionLabel(at index: Int) -> String {
        switch index {
        case 0: "첫 번째 원문 보기"
        case 1: "두 번째 원문 보기"
        default: "\(index + 1)번째 원문 보기"
        }
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        ".?!。？！".contains(character)
    }
}

/// Quiet, provider-independent intelligence canvas. This view only renders values and
/// forwards explicit actions; opening it cannot start analysis or model work.
struct LivingMarginView: View {
    @ObservedObject var model: LivingMarginModel
    let mode: WritingMode
    let theme: PurloryTheme
    var onJumpToEvidence: (MarginInsight, EvidenceAnchor) -> Void
    var onAction: ((MarginInsight, MarginAction) -> Void)?
    var supportsAction: ((MarginInsight) -> Bool)? = nil
    var spatial: SpatialWorkspaceController? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var insights: [MarginInsight] {
        model.visibleInsights(for: mode)
    }

    var body: some View {
        Group {
            if insights.isEmpty {
                if spatial != nil {
                    Text("아직 마진 노트가 없어요. ✨ 버튼으로 현재 문단의 제안을 받을 수 있어요.")
                        .purloryUIFont(11).foregroundStyle(theme.workspaceMutedC).padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else { emptyState }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(insights) { insight in
                            if let spatial {
                                WorkspaceCompactCard(model: spatial, id: "margin.\(insight.id)", title: insight.title, detail: insight.message,
                                    term: insight.evidence.first?.quote ?? "", theme: theme, serif: true,
                                    sourceDocumentID: insight.evidence.first?.documentID) {
                                    Text(insight.message).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Spacer()
                                        if let anchor = insight.evidence.first {
                                            Button("본문 이동 →") { onJumpToEvidence(insight, anchor) }
                                                .buttonStyle(.plain).purloryUIFont(10, .medium).foregroundStyle(theme.novelC)
                                        }
                                    }
                                    ForEach(customActions(insight)) { action in
                                        Button(action.title) { onAction?(insight, action) }.buttonStyle(.plain).purloryUIFont(10).foregroundStyle(theme.novelC)
                                    }
                                }.padding(.horizontal, 8).padding(.top, 6)
                                    .contextMenu { Button("제안 닫기") { dismiss(insight.id) } }
                            } else { insightRow(insight) }
                            if spatial == nil && insight.id != insights.last?.id {
                                theme.sepC.frame(height: 1)
                                    .padding(.horizontal, PurlorySpacing.lg)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .animation(
            reduceMotion || spatial != nil ? nil : .spring(response: 0.26, dampingFraction: 0.9),
            value: insights.map(\.id)
        )
        .accessibilityIdentifier("purlory.living-margin")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: PurlorySpacing.sm) {
            Text("지금 보여드릴 제안이 없어요")
                .purloryUIFont(12, .medium)
                .foregroundStyle(theme.ink2C)
            Text("확실한 맥락이나 문장 제안만 이 여백에 조용히 표시됩니다.")
                .purloryUIFont(11)
                .foregroundStyle(theme.ink3C)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(PurlorySpacing.lg)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func insightRow(_ insight: MarginInsight) -> some View {
        let descriptor = LivingMarginRenderer.descriptor(for: insight.kind)
        let row = VStack(alignment: .leading, spacing: PurlorySpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: PurlorySpacing.sm) {
                Label(descriptor.categoryLabel, systemImage: descriptor.systemImage)
                    .purloryUIFont(10, .semibold)
                    .foregroundStyle(theme.novelC)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: PurlorySpacing.sm)
                Button {
                    dismiss(insight.id)
                } label: {
                    Image(systemName: "xmark")
                        .purloryUIFont(10, .medium)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.ink3C)
                .accessibilityLabel("제안 닫기")
                .help("이 제안 닫기")
            }

            VStack(alignment: .leading, spacing: PurlorySpacing.xs) {
                Text(insight.title)
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.inkC)
                Text(insight.message)
                    .purloryUIFont(12)
                    .foregroundStyle(theme.ink2C)
                    .fixedSize(horizontal: false, vertical: true)
                if let guidance = descriptor.guidance {
                    Text(guidance)
                        .purloryUIFont(10, .medium)
                        .foregroundStyle(theme.ink3C)
                }
            }

            if !insight.evidence.isEmpty || hasCustomActions(insight) {
                VStack(alignment: .leading, spacing: PurlorySpacing.sm) {
                    ForEach(Array(insight.evidence.enumerated()), id: \.offset) { index, anchor in
                        Button {
                            onJumpToEvidence(insight, anchor)
                        } label: {
                            Label(
                                LivingMarginRenderer.evidenceActionLabel(at: index),
                                systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(.plain)
                        .purloryUIFont(11, .medium)
                        .foregroundStyle(theme.blueC)
                    }
                    ForEach(customActions(insight)) { action in
                        Button(action.title) { onAction?(insight, action) }
                            .buttonStyle(.plain)
                            .purloryUIFont(11, .medium)
                            .foregroundStyle(theme.blueC)
                    }
                }
            }
        }
        .padding(PurlorySpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LivingMarginRenderer.accessibilitySummary(for: insight))
        .accessibilityAction(named: Text("제안 닫기")) { dismiss(insight.id) }

        if let firstEvidence = insight.evidence.first {
            row.accessibilityAction(named: Text("원문 보기")) {
                onJumpToEvidence(insight, firstEvidence)
            }
        } else {
            row
        }
    }

    private func customActions(_ insight: MarginInsight) -> [MarginAction] {
        guard onAction != nil, supportsAction?(insight) != false else { return [] }
        return insight.actions.filter { action in
            action.kind != .jumpToEvidence && action.kind != .dismiss
        }
    }

    private func hasCustomActions(_ insight: MarginInsight) -> Bool {
        !customActions(insight).isEmpty
    }

    private func dismiss(_ insightID: String) {
        if reduceMotion {
            model.dismiss(insightID)
        } else {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                model.dismiss(insightID)
            }
        }
    }
}
