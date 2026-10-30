@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class LivingMarginModelTests: XCTestCase {
    func testGeneralAndFictionUseOneContractWithDifferentCapabilities() {
        let insights = MarginInsight.Kind.allCases.enumerated().map {
            insight(id: "\($0.offset)", kind: $0.element)
        }

        XCTAssertEqual(
            LivingMarginPolicy.present(insights, mode: .general).map(\.kind),
            [.writingQuality, .suggestion, .generalReview])
        XCTAssertEqual(
            LivingMarginPolicy.present(insights, mode: .fiction).map(\.kind),
            [
                .continuity, .writingQuality, .openThread, .sceneContext, .suggestion,
                .generalReview,
            ])
    }

    func testSuppressesLowConfidenceAndUnevidencedContinuityWarnings() {
        let visible = insight(id: "visible", kind: .suggestion, confidence: 0.7)
        let quiet = insight(id: "quiet", kind: .suggestion, confidence: 0.69)
        let unsupportedWarning = MarginInsight(
            id: "no-evidence",
            kind: .continuity,
            title: "Potential conflict",
            message: "Please confirm this detail.",
            confidence: 0.99)

        XCTAssertEqual(
            LivingMarginPolicy.present([quiet, unsupportedWarning, visible], mode: .fiction)
                .map(\.id),
            ["visible"])
    }

    func testDeduplicatesByIDAndEquivalentContent() {
        let first = insight(id: "same", kind: .suggestion, confidence: 0.8)
        var stronger = first
        stronger.confidence = 0.95
        let duplicateContent = MarginInsight(
            id: "different-id",
            kind: first.kind,
            title: "  \(first.title.uppercased())  ",
            message: "\(first.message)\n",
            evidence: [
                EvidenceAnchor(
                    documentID: WritingDocumentID(),
                    quote: "Second occurrence")
            ],
            confidence: 0.9)

        let presented = LivingMarginPolicy.present(
            [first, duplicateContent, stronger], mode: .fiction)

        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(presented.first?.id, "same")
        XCTAssertEqual(presented.first?.confidence, 0.95)
        XCTAssertEqual(presented.first?.evidence.count, 2)
    }

    func testOrderingIsPriorityThenStableInputOrder() {
        let insights = [
            insight(id: "review", kind: .generalReview),
            insight(id: "suggestion-b", kind: .suggestion),
            insight(id: "thread", kind: .openThread),
            insight(id: "suggestion-a", kind: .suggestion),
            insight(id: "quality", kind: .writingQuality),
            insight(id: "continuity", kind: .continuity),
        ]

        XCTAssertEqual(
            LivingMarginPolicy.present(insights, mode: .fiction).map(\.id),
            ["continuity", "quality", "thread", "suggestion-b", "suggestion-a", "review"])
    }

    func testStableBoundsAtZeroOneFiveAndTwentyItems() {
        for requestedCount in [0, 1, 5, 20] {
            let insights = (0..<requestedCount).map {
                insight(id: "item-\($0)", kind: .suggestion)
            }
            XCTAssertEqual(
                LivingMarginPolicy.present(insights, mode: .general).count,
                requestedCount)
        }

        let overflow = (0..<25).map { insight(id: "item-\($0)", kind: .suggestion) }
        XCTAssertEqual(LivingMarginPolicy.present(overflow, mode: .general).count, 20)
    }

    func testModelReplacementAndDismissalArePresentationOnly() {
        let model = LivingMarginModel()
        let first = insight(id: "first", kind: .suggestion)
        let second = insight(id: "second", kind: .writingQuality)

        model.replace(with: [first, second])
        model.dismiss("first")

        XCTAssertEqual(model.visibleInsights(for: .general).map(\.id), ["second"])
        XCTAssertEqual(model.insights.map(\.id), ["first", "second"])

        model.replace(with: [first])
        XCTAssertTrue(model.visibleInsights(for: .general).isEmpty)

        model.restoreDismissed()
        XCTAssertEqual(model.visibleInsights(for: .general).map(\.id), ["first"])
    }

    func testDismissingGroupedContentDoesNotRevealItsDuplicate() {
        let model = LivingMarginModel()
        let first = insight(id: "first", kind: .writingQuality, confidence: 0.8)
        let duplicate = MarginInsight(
            id: "duplicate",
            kind: .writingQuality,
            title: "  \(first.title.uppercased()) ",
            message: "\(first.message)\n",
            evidence: first.evidence,
            confidence: 0.9)
        model.replace(with: [first, duplicate])
        let visibleID = model.visibleInsights(for: .general).first?.id

        XCTAssertNotNil(visibleID)
        model.dismiss(visibleID ?? "")

        XCTAssertTrue(model.visibleInsights(for: .general).isEmpty)
        XCTAssertEqual(model.dismissedIDs, Set(["first", "duplicate"]))
    }

    private func insight(
        id: String,
        kind: MarginInsight.Kind,
        confidence: Double? = nil
    ) -> MarginInsight {
        let evidence = EvidenceAnchor(
            documentID: WritingDocumentID(),
            quote: "Evidence for \(id)")
        return MarginInsight(
            id: id,
            kind: kind,
            title: "Title \(id)",
            message: "Message \(id)",
            evidence: [evidence],
            confidence: confidence)
    }
}
