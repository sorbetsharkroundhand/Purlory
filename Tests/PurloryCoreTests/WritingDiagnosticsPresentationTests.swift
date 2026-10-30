@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class WritingDiagnosticsPresentationTests: XCTestCase {
    func testPreparedPresentationIsQuietAndExplainsOriginalEvidence() throws {
        let spelling = presentationFinding(id: "spelling", offset: 0)
        var style = presentationFinding(id: "style", offset: 4)
        style.diagnostic.category = .style; style.diagnostic.kind = .repeatedEnding; style.diagnostic.severity = .suggestion
        style.diagnostic.alternatives = []
        style.diagnostic.message = "어미가 반복됩니다."; style.diagnostic.reason = "가까운 문장에서 같은 어미가 이어집니다."
        var info = style; info.diagnostic.severity = .info
        var uncertain = spelling; uncertain.diagnostic.confidence = 0.4
        var state = WritingDiagnosticsState(); state.findings = [spelling, style, info, uncertain]
        let insights = WritingDiagnosticsPresentation.insights(from: state)
        XCTAssertEqual(insights.count, 2)
        XCTAssertTrue(insights.allSatisfy { $0.kind == .writingQuality && !$0.evidence.isEmpty })
        let correctness = try XCTUnwrap(insights.first { $0.evidence.first?.utf16Hint == 0 })
        XCTAssertTrue(LivingMarginRenderer.accessibilitySummary(for: correctness).contains("맞춤법"))
        XCTAssertTrue(correctness.actions.contains { $0.title.contains("됐다") })
        XCTAssertEqual(correctness.evidence.first?.quote, "됬다")
        XCTAssertTrue(insights.contains { $0.message.contains("가까운 문장") })
        XCTAssertTrue(WritingDiagnosticsPresentation.insights(from: WritingDiagnosticsState()).isEmpty)
    }

    func testActionIDsBindCurrentStampAndExactAlternativeWithoutEmbeddingWriterText() {
        let first = presentationFinding(id: "stable-occurrence", offset: 0)
        let original = WritingDiagnosticsPresentation.bindings(for: first).first!.action
        var changed = first
        changed.diagnostic.alternatives = ["다른 표현"]
        let candidate = WritingDiagnosticsPresentation.bindings(for: changed).first!.action
        XCTAssertNotEqual(original.id, candidate.id)
        changed = first
        changed.stamp = .init(runtime: first.stamp.runtime, nativeRevision: 2, profileRevision: 1,
            providerRevision: first.stamp.providerRevision, ruleRevision: first.stamp.ruleRevision, windowDigest: first.stamp.windowDigest)
        XCTAssertNotEqual(original.id, WritingDiagnosticsPresentation.bindings(for: changed).first!.action.id)
        XCTAssertFalse(original.id.contains("됐다"))
        XCTAssertFalse(candidate.id.contains("다른 표현"))
    }

    func testProducerReplacementRetainsStoryAndSessionDismissals() {
        let story = MarginInsight(id: "story", kind: .sceneContext, title: "장면", message: "준비된 장면")
        let model = LivingMarginModel(insights: [story])
        var state = WritingDiagnosticsState(); state.findings = [presentationFinding(id: "quality", offset: 0)]
        let writing = WritingDiagnosticsPresentation.insights(from: state)
        model.replace(writingQuality: writing)
        XCTAssertEqual(Set(model.insights.map(\.id)), Set([story.id] + writing.map(\.id)))
        model.dismiss(writing[0].id)
        model.replace(writingQuality: writing)
        XCTAssertEqual(model.visibleInsights(for: .fiction).map(\.id), [story.id])
        let nextStory = MarginInsight(id: "next-story", kind: .sceneContext, title: "다음 장면", message: "새 준비된 장면")
        model.replace(with: [nextStory])
        XCTAssertEqual(Set(model.insights.map(\.id)), Set([nextStory.id] + writing.map(\.id)))
        XCTAssertEqual(model.visibleInsights(for: .fiction).map(\.id), [nextStory.id])
        model.replace(writingQuality: [])
        XCTAssertEqual(model.insights.map(\.id), [nextStory.id])
    }

    func testPreparedRelatedAnchorsKeepOriginalUnitsAndShiftThroughUnrelatedEdit() async throws {
        let original = String(repeating: "가", count: 10_000) + "\n**됬다** 그리고 는 는"
        let holder = WritingReportSnapshotHolder(WritingReportSnapshotHolder.snapshot(original))
        let clock = ManualDiagnosticsClock()
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [RelatedAnchorProbe()]),
            clock: clock, currentSnapshot: { holder.value })
        defer { controller.cancel() }
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: holder.value.identity, nativeRevision: 1,
            patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: []), markedRange: nil), snapshot: holder.value)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        let first = try XCTUnwrap(controller.state.findings.first)
        XCTAssertEqual(first.relatedEvidence.count, 2)
        XCTAssertEqual(first.relatedEvidence.map { Array($0.quote.utf16) }, [Array("는".utf16), Array("는".utf16)])
        for anchor in first.relatedEvidence {
            XCTAssertEqual(Array((original as NSString).substring(with: .init(location: try XCTUnwrap(anchor.utf16Hint), length: anchor.quote.utf16.count)).utf16), Array(anchor.quote.utf16))
        }
        let previous = holder.value
        holder.value = .init(identity: .init(key: previous.identity.key, generation: previous.identity.generation + 1),
            title: previous.title, body: "밖 " + original, kind: .manuscript, mode: .general)
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: previous.identity, nativeRevision: 2,
            patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: WritingProseProjection.blocks(source: "밖 ")),
            markedRange: nil), snapshot: holder.value)
        let shifted = try XCTUnwrap(controller.state.findings.first { $0.id == first.id })
        XCTAssertEqual(shifted.relatedEvidence.map(\.utf16Hint), first.relatedEvidence.map { $0.utf16Hint.map { $0 + 2 } })
        XCTAssertEqual(shifted.relatedEvidence.map { Array($0.quote.utf16) }, first.relatedEvidence.map { Array($0.quote.utf16) })
    }

    func testReportBudgetIncludesPreparedRelatedAnchorQuotes() async throws {
        let body = "가" + String(repeating: "나", count: 1024)
        let projection = try WritingProjectionSnapshot.prepare(source: body)
        let snapshot = WritingReportSnapshotHolder.snapshot(body)
        let diagnostic = WritingDiagnostic(id: "synthetic", ruleID: "related", providerID: "probe", category: .style, kind: .repeatedWord,
            severity: .suggestion, range: .init(location: 0, length: 1), relatedRanges: [.init(location: 1, length: 1024)],
            message: "Synthetic related-anchor budget fixture", languageTag: "ko")
        let baseCost = 512 + WritingDiagnosticsCache.diagnosticCost(diagnostic) + WritingDiagnosticsCache.stringCost("가") + 64
        let mapper = WritingReportMapper(projection: projection, prose: body, sourceRevision: "synthetic", profile: WritingStyleRecord(),
            identity: snapshot.identity, profileRevision: 1, providerRevision: "probe", ruleRevision: 1, findingBudgetBytes: baseCost + 512)
        let packet = try await mapper.consume(.init(diagnostics: [diagnostic], assessedRange: .init(location: 0, length: body.utf16.count),
            totalProseUTF16: body.utf16.count, unsupportedRanges: []))
        XCTAssertTrue(packet.findings.isEmpty, "Original related quotes belong to the same bounded finding account")
        let coverage = await mapper.finish(); XCTAssertFalse(coverage.isComplete)
    }

    func testRelatedOriginalEvidenceAndIndependentCorrectionsStaySeparate() {
        var first = presentationFinding(id: "first", offset: 0)
        let second = presentationFinding(id: "second", offset: 4)
        let original = "는"
        first.relatedEvidence = [.init(documentID: first.evidence.documentID, quote: original, utf16Hint: 8)]
        var state = WritingDiagnosticsState(); state.findings = [first, second]
        let values = WritingDiagnosticsPresentation.insights(from: state)
        let model = LivingMarginModel(); model.replace(writingQuality: values)
        XCTAssertEqual(model.visibleInsights(for: .general).count, 2, "Independent targets cannot share an ambiguous correction button")
        XCTAssertEqual(values[0].evidence.count, 2)
        XCTAssertEqual(Array(values[0].evidence[1].quote.utf16), Array(original.utf16))
    }
}

func presentationFinding(id: String, offset: Int) -> WritingDiagnosticsFinding {
    let key = ProjectDocumentKey(projectID: WritingProjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000126")!),
        documentID: WritingDocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000127")!))
    let diagnostic = WritingDiagnostic(id: id, ruleID: "ko.correctness.doeda-past", providerID: "probe", category: .correctness,
        kind: .spelling, severity: .correctness, range: .init(location: offset, length: 2), message: "‘됬다’를 ‘됐다’로 고칠 수 있습니다.",
        reason: "분석된 ‘되다’의 과거형은 ‘됐다’로 적습니다.", alternatives: ["됐다"], languageTag: "ko")
    return WritingDiagnosticsFinding(id: id, diagnostic: diagnostic, sourceRanges: [.init(location: offset, length: 2)], relatedSourceRanges: [],
        evidence: .init(documentID: key.documentID, quote: "됬다", utf16Hint: offset), contextRange: .init(location: 0, length: 20),
        stamp: .init(runtime: .init(key: key, generation: 1), nativeRevision: 1, profileRevision: 1, providerRevision: "probe", ruleRevision: 3, windowDigest: "synthetic"))
}

private struct RelatedAnchorProbe: WritingDiagnosticsProvider {
    let id = "related-anchor-probe"
    func analyze(_ request: WritingDiagnosticsRequest) async throws -> [WritingDiagnostic] {
        let text = request.text as NSString, primary = (request.text as NSString).range(of: "됬다")
        guard primary.location != NSNotFound else { return [] }
        let decomposed = text.range(of: "는", options: .literal), composed = text.range(of: "는", options: [.literal, .backwards])
        return [.init(id: "synthetic-related", ruleID: "fixture.related", providerID: id, category: .style, kind: .repeatedEnding,
            severity: .suggestion, range: .init(primary), relatedRanges: [.init(decomposed), .init(composed)],
            message: "Synthetic source-anchor mapping fixture", languageTag: "ko")]
    }
}
