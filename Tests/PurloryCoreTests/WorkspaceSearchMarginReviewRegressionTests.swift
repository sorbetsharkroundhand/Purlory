@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import AppKit
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class WorkspaceSearchMarginReviewRegressionTests: XCTestCase {
    // MARK: - F15

    func testCommandSearchFindsSourceMatchesBeyondFortySixCharactersAndIncludesMatchedExcerpt() throws {
        let prefix70 = String(repeating: "가", count: 70)
        let prefix120Emoji = String(repeating: "나🙂", count: 45)
        let body = """
        \(prefix70)희귀단어가 문단 후반부에 등장합니다.

        \(prefix120Emoji) 끝에있는검색어입니다.
        """
        let document = WritingDocument(
            id: WritingDocumentID(),
            title: "장편 원고",
            body: body,
            kind: .manuscript
        )
        let project = WritingProject(
            id: WritingProjectID(),
            title: "검색 회귀",
            mode: .fiction,
            documents: [document]
        )

        let firstResults = WorkspaceCommandSearch.search(in: project, query: "희귀단어")
        let firstSource = try XCTUnwrap(firstResults.first { $0.kind == .source })
        XCTAssertTrue(
            firstSource.title.localizedCaseInsensitiveContains("희귀단어"),
            "Source item title (\(firstSource.title)) must include the matched query text even past character 46"
        )
        guard case .source(let firstRef) = firstSource.action else {
            return XCTFail("Expected .source action")
        }
        XCTAssertTrue(firstRef.matchesSource(document.body))
        XCTAssertTrue(firstRef.evidence.quote.contains("희귀단어"))

        let secondResults = WorkspaceCommandSearch.items(
            in: project,
            query: "끝에있는검색어",
            typewriter: false,
            focus: false
        )
        let secondSource = try XCTUnwrap(secondResults.first { $0.kind == .source })
        XCTAssertTrue(secondSource.title.localizedCaseInsensitiveContains("끝에있는검색어"))
        guard case .source(let secondRef) = secondSource.action else {
            return XCTFail("Expected .source action")
        }
        XCTAssertTrue(secondRef.matchesSource(document.body))
        XCTAssertTrue(secondRef.evidence.quote.contains("끝에있는검색어"))
    }

    // MARK: - F16

    func testCommandSearchMemoizesSourceMetadataAcrossRepeatedQueriesOnLargeManuscript() {
        var lines: [String] = ["# 장편 소설"]
        lines.reserveCapacity(7_000)
        let filler = "마을 앞 넓은 들판에는 차가운 가을 바람이 불고 사람들은 긴 황톳길을 걸어갔다."
        for index in 0..<3_500 {
            lines.append("제\(index + 1)문단 \(filler)")
            lines.append("")
        }
        let largeBody = lines.joined(separator: "\n")
        XCTAssertGreaterThan(largeBody.utf16.count, 180_000)

        let document = WritingDocument(
            id: WritingDocumentID(),
            title: "대형 원고",
            body: largeBody,
            kind: .manuscript
        )
        let project = WritingProject(
            id: WritingProjectID(),
            title: "성능 회귀",
            mode: .fiction,
            documents: [document]
        )

        // First search populates the per-(document.id, document.source) metadata cache.
        let initial = WorkspaceCommandSearch.search(in: project, query: "제100문단", limit: 9)
        XCTAssertTrue(initial.contains { $0.kind == .source && $0.title.contains("제100문단") })

        let hashesBefore = WorkspaceCommandSearch.revisionHashCount
        for query in ["제500문단", "제1500문단", "제2500문단", "제3400문단", "존재하지않는단어"] {
            let results = WorkspaceCommandSearch.search(in: project, query: query, limit: 9)
            if query != "존재하지않는단어" {
                XCTAssertTrue(results.contains { $0.kind == .source && $0.title.contains(query) })
            } else {
                XCTAssertTrue(results.isEmpty)
            }
        }
        let hashesAfter = WorkspaceCommandSearch.revisionHashCount
        XCTAssertEqual(
            hashesAfter,
            hashesBefore,
            "Repeated searches on an unchanged DocumentSource must reuse the cached revision digest"
        )
    }

    // MARK: - F28

    func testMarginSuggestionInsertionDoesNotDuplicateWritingQualityInsightsAndScopingClearsStaleDocumentInsights() async throws {
        let projectID = WritingProjectID()
        let docA = ProjectDocumentKey(projectID: projectID, documentID: WritingDocumentID())
        let docB = ProjectDocumentKey(projectID: projectID, documentID: WritingDocumentID())

        let margin = LivingMarginModel()
        margin.scope(to: docA)

        let qualityInsight = MarginInsight(
            id: "writing-quality:typo-1",
            kind: .writingQuality,
            title: "맞춤법 확인",
            message: "'됬다' 대신 '됐다'를 권장합니다.",
            evidence: [EvidenceAnchor(documentID: docA.documentID, quote: "됬다", utf16Hint: 0)]
        )
        margin.replace(writingQuality: [qualityInsight])
        XCTAssertEqual(margin.insights.map(\.id), ["writing-quality:typo-1"])

        let suggestionInsight = MarginInsight(
            id: "workspace.suggestion-1",
            kind: .suggestion,
            title: "장면 감각 보강",
            message: "바람 소리를 한 줄 더해 보세요.",
            evidence: [EvidenceAnchor(documentID: docA.documentID, quote: "첫 문단.", utf16Hint: 0)]
        )
        margin.prepend(suggestionInsight, for: docA)
        XCTAssertEqual(margin.insights.map(\.id), ["workspace.suggestion-1", "writing-quality:typo-1"])

        // Clearing writingQuality insights must remove all writingQuality items without leaving a duplicate in otherProducerInsights.
        margin.replace(writingQuality: [])
        XCTAssertEqual(margin.insights.map(\.id), ["workspace.suggestion-1"])

        // Switching scope to another document clears stale insights from the previous document.
        margin.scope(to: docB)
        XCTAssertTrue(margin.insights.isEmpty)

        // End-to-end check with WorkspaceAssistance(.margin) while writingQualityInsights are present.
        let h = try await FramedWorkspaceHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("첫 문단입니다.\n\n두 번째 문단입니다.")
        let editor = try await h.editor()
        let activeDocID = try XCTUnwrap(h.fixture.session.selectedDocumentID)
        let workspaceMargin = LivingMarginModel()
        workspaceMargin.replace(writingQuality: [
            MarginInsight(
                id: "writing-quality:live-1",
                kind: .writingQuality,
                title: "띄어쓰기",
                message: "띄어쓰기를 확인해 주세요.",
                evidence: [EvidenceAnchor(documentID: activeDocID, quote: "첫 문단입니다.", utf16Hint: 0)]
            )
        ])
        let assistance = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: workspaceMargin) { _, _ in
            AskAnswerGeneration { emit in try emit("호흡 조절 | 문단 사이의 여운을 살려 보세요.") }
        }
        let applied = await assistance.runInline(.margin, editor: editor)
        XCTAssertTrue(applied)
        XCTAssertEqual(workspaceMargin.insights.count, 2)

        workspaceMargin.replace(writingQuality: [])
        XCTAssertEqual(workspaceMargin.insights.count, 1)
        XCTAssertEqual(workspaceMargin.insights.first?.kind, .suggestion)
        XCTAssertEqual(workspaceMargin.insights.first?.title, "호흡 조절")
    }

    // MARK: - F29

    func testReviewJudgeControllerInvalidatedByManuscriptEditIsReplacedOnRetryAndPrunedWhenStale() async throws {
        let f = try await LegacyBoundaryFixture(mode: .fiction)
        defer { f.cleanUp() }
        f.session.updateSelectedDocumentBody("민준은 서울에 있었다.\n민준은 부산에 있었다.\n")

        func makeCandidate() throws -> ContinuityCandidate {
            let actor = CharacterCard(name: "민준")
            let document = try XCTUnwrap(f.session.selectedDocumentSnapshot)
            let scope = StoryMemoryScope.project(
                projectID: document.identity.key.projectID,
                documentID: document.identity.key.documentID
            )
            let time = StoryInterval.point(.init(timelineID: UUID(), tick: 1))
            let quotes = ["민준은 서울에 있었다.", "민준은 부산에 있었다."]
            let facts = quotes.enumerated().map { index, quote in
                let start = (document.body as NSString).range(of: quote).location
                return StoryFact(
                    derivedID: "location-\(index)",
                    scope: scope,
                    content: .characterState(.init(characterID: actor.id, field: .location, value: index == 0 ? "서울" : "부산")),
                    evidence: .init(documentID: scope.documentID, quote: quote, utf16Hint: start),
                    discourseRange: start..<(start + quote.utf16.count),
                    storyInterval: time,
                    confidence: 0.9,
                    origin: .deterministic(ruleID: "fixture")
                )
            }
            let snapshot = StoryKnowledgeSnapshot(scope: scope, source: document.body, facts: facts, entities: .init(characters: [actor]))
            return try XCTUnwrap(ContinuityCandidate.prepare(snapshot: snapshot, before: document.body.utf16.count).first)
        }

        let support = ContinuityJudgeSupport(available: true) { packet in
            let raw = String(
                decoding: try JSONSerialization.data(withJSONObject: [
                    "packet": packet.id.uuidString,
                    "verdict": "conflict",
                    "confidence": 0.92,
                    "explanation": "동일 시점의 위치가 서로 다릅니다.",
                    "citations": [1, 2]
                ]),
                as: UTF8.self
            )
            return AskAnswerGeneration { emit in try emit(raw) }
        }
        defer { support.shutdown() }

        var controllers: [String: ContinuityJudgeController] = [:]
        let issueID = "continuity.issue.1"
        let firstOrigin = try XCTUnwrap(f.session.runtimeIdentity)
        let firstCandidate = try makeCandidate()

        let firstController = WorkspaceReviewPane.requestJudgment(
            for: issueID,
            candidate: firstCandidate,
            origin: firstOrigin,
            in: &controllers,
            session: f.session,
            support: support
        )
        let firstDone = expectation(description: "First judgment completes")
        let sub1 = firstController.$status.filter { $0 == .needsReview }.prefix(1).sink { _ in firstDone.fulfill() }
        await fulfillment(of: [firstDone], timeout: 2)
        withExtendedLifetime(sub1) {}
        XCTAssertEqual(firstController.origin, firstOrigin)
        XCTAssertTrue(firstController.matches(firstOrigin))

        // Editing the manuscript advances runtimeIdentity and invalidates firstController.
        f.session.updateSelectedDocumentBody("민준은 서울에 있었다.\n민준은 부산에 있었다.\n새로운 문장이 추가되었다.\n")
        let secondOrigin = try XCTUnwrap(f.session.runtimeIdentity)
        XCTAssertNotEqual(secondOrigin, firstOrigin)
        firstController.noteContextChanged(to: secondOrigin)
        XCTAssertEqual(firstController.status, .invalidated)
        XCTAssertFalse(firstController.matches(secondOrigin))

        // Re-requesting judgment for the same issueID at secondOrigin must replace the invalidated controller.
        let secondCandidate = try makeCandidate()
        let secondController = WorkspaceReviewPane.requestJudgment(
            for: issueID,
            candidate: secondCandidate,
            origin: secondOrigin,
            in: &controllers,
            session: f.session,
            support: support
        )
        XCTAssertFalse(secondController === firstController)
        XCTAssertEqual(secondController.origin, secondOrigin)
        let secondDone = expectation(description: "Second judgment completes with fresh controller")
        let sub2 = secondController.$status.filter { $0 == .needsReview }.prefix(1).sink { _ in secondDone.fulfill() }
        await fulfillment(of: [secondDone], timeout: 2)
        withExtendedLifetime(sub2) {}
        XCTAssertEqual(secondController.status, .needsReview)

        // Pruning removes controllers whose issueID is no longer active.
        WorkspaceReviewPane.pruneJudgeControllers(&controllers, origin: secondOrigin, activeIssueIDs: [])
        XCTAssertTrue(controllers.isEmpty)
        XCTAssertEqual(secondController.status, .invalidated)
    }
}
