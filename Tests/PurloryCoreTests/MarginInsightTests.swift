@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class MarginInsightTests: XCTestCase {
    func testContractSupportsEverySharedInsightKind() {
        XCTAssertEqual(
            Set(MarginInsight.Kind.allCases),
            Set([
                .continuity,
                .openThread,
                .sceneContext,
                .suggestion,
                .writingQuality,
                .generalReview,
            ]))
    }

    func testInsightAndActionsHaveStableValueIdentity() {
        let evidence = EvidenceAnchor(
            documentID: WritingDocumentID(),
            quote: "A source sentence")
        let action = MarginAction(
            id: "intentional",
            kind: .markIntentional,
            title: "의도한 표현")
        let insight = MarginInsight(
            id: "quality-1",
            kind: .writingQuality,
            title: "비슷한 어미가 이어져요",
            message: "리듬을 한 번 확인해 보세요.",
            evidence: [evidence],
            confidence: 0.92,
            actions: [action])

        XCTAssertEqual(insight.id, "quality-1")
        XCTAssertEqual(insight.actions, [action])
        XCTAssertEqual(action.id, "intentional")
    }
}
