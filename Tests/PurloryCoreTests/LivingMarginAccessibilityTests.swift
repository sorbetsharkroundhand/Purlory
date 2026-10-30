@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class LivingMarginAccessibilityTests: XCTestCase {
    func testEveryKindHasAReadableCategoryAndSymbol() {
        for kind in MarginInsight.Kind.allCases {
            let descriptor = LivingMarginRenderer.descriptor(for: kind)
            XCTAssertFalse(descriptor.categoryLabel.isEmpty)
            XCTAssertFalse(descriptor.systemImage.isEmpty)
        }
    }

    func testContinuityUsesConfirmatoryLanguage() {
        let descriptor = LivingMarginRenderer.descriptor(for: .continuity)

        XCTAssertEqual(descriptor.categoryLabel, "이어짐 확인")
        XCTAssertEqual(descriptor.guidance, "원문과 함께 확인해 보세요")
    }

    func testAccessibilitySummaryIncludesCategoryTitleMessageAndEvidenceCount() {
        let insight = MarginInsight(
            id: "warning",
            kind: .continuity,
            title: "시간 흐름이 달라질 수 있어요",
            message: "앞 장면에서는 해가 지고 있었어요.",
            evidence: [
                EvidenceAnchor(documentID: WritingDocumentID(), quote: "해가 지고 있었다")
            ])

        XCTAssertEqual(
            LivingMarginRenderer.accessibilitySummary(for: insight),
            "이어짐 확인. 시간 흐름이 달라질 수 있어요. 앞 장면에서는 해가 지고 있었어요. 원문 1곳")
    }

    func testVisibleActionLabelsIncludeEvidenceCustomActionsAndDismissal() {
        let insight = MarginInsight(
            id: "quality",
            kind: .writingQuality,
            title: "어미 반복",
            message: "리듬을 확인해 보세요.",
            evidence: [
                EvidenceAnchor(documentID: WritingDocumentID(), quote: "문장 하나"),
                EvidenceAnchor(documentID: WritingDocumentID(), quote: "문장 둘"),
            ],
            actions: [
                MarginAction(
                    id: "intentional",
                    kind: .markIntentional,
                    title: "의도한 표현")
            ])

        XCTAssertEqual(
            LivingMarginRenderer.actionLabels(for: insight),
            ["첫 번째 원문 보기", "두 번째 원문 보기", "의도한 표현", "제안 닫기"])
    }
}
