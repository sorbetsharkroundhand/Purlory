@testable import PurloryDocumentEngine
import XCTest
@testable import PurloryCore

@MainActor
final class FictionReviewProjectionTests: XCTestCase {
    private let person = CharacterCard(name: "민준"), other = CharacterCard(name: "서연")
    private let timeline = UUID()
    private func fixture(prefix: String = "", identity supplied: ProjectRuntimeIdentity? = nil, knownTime: Bool = true,
                         confidence: Double = 0.9, resolved: Bool = false, eventsHaveOriginals: Bool = true,
                         cyclic: Bool = false) -> (ProjectDocumentSnapshot, KnowledgeSnapshot, [ContinuityCandidate]) {
        let source = "# 시작\n" + prefix + "민준은 문을 열었다.\n민준은 알고 있었다.\n민준은 모르고 있었다.\n민준은 서울에 있었다.\n민준은 부산에 있었다.\n# 다음\n민준은 돌아왔다.\n"
        let identity = supplied ?? .init(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1)
        let doc = ProjectDocumentSnapshot(identity: identity, title: "Novel", body: source, kind: .manuscript, mode: .fiction, userData: [:])
        let scope = StoryMemoryScope.project(projectID: identity.key.projectID, documentID: identity.key.documentID)
        let quotes = ["민준은 알고 있었다.", "민준은 모르고 있었다.", "민준은 서울에 있었다.", "민준은 부산에 있었다."]
        let time: StoryInterval = knownTime ? .point(.init(timelineID: timeline, tick: 1)) : .unknown
        let facts = quotes.enumerated().map { index, quote -> StoryFact in
            let start = (source as NSString).range(of: quote).location
            let content: StoryFact.Content = index < 2
                ? .characterKnowledge(.init(characterID: person.id, fact: "문을 열기", stance: index == 0 ? .knows : .unaware))
                : .characterState(.init(characterID: person.id, field: .location, value: index == 2 ? "서울" : "부산"))
            return .init(derivedID: "fact-\(index)", scope: scope, content: content,
                evidence: .init(documentID: scope.documentID, quote: quote, utf16Hint: start), discourseRange: start..<(start + quote.utf16.count),
                storyInterval: time, confidence: 0.9, origin: .deterministic(ruleID: "fixture"))
        }
        let story = StoryKnowledgeSnapshot(scope: scope, source: source, facts: facts, entities: .init(characters: [person]))
        let outline = DocumentOutline.parse(source)
        let events = outline.scenes.enumerated().map { index, scene in
            StoryEvent(sceneHash: scene.contentHash, participants: [person.id], summary: "사건 \(index)", importance: 3,
                quote: eventsHaveOriginals ? (index == 0 ? "민준은 문을 열었다." : "민준은 돌아왔다.") : nil)
        }
        let local = (source as NSString).range(of: "민준은 문을 열었다.").location - outline.scenes[0].utf16Range.lowerBound
        let segment = NarrativeSegment(sceneHash: outline.scenes[0].contentHash, localStart: local,
            localEnd: outline.scenes[0].utf16Range.count, startQuote: "민준은 문을 열었다.", layer: .flashback,
            returnState: .uncertain, confidence: confidence, persistentID: "segment-fixed")
        let threads = PlotThreadAnalysis(threads: [.init(stableID: "plot", title: "열린 약속", memberships: events.map { .init(eventKey: $0.stableKey) }, resolvedAtKey: resolved ? events.last?.stableKey : nil, confidence: 0.9)])
        let graph = cyclic ? EventGraphAnalysis(chronoEdges: [.init(aKey: events[0].stableKey, bKey: events[1].stableKey, relation: .before),
            .init(aKey: events[1].stableKey, bKey: events[0].stableKey, relation: .before)]) : nil
        let snapshot = KnowledgeSnapshot(entryID: identity.key.documentID.rawValue, outline: outline, summariesByHash: [:], storyKnowledge: story,
            events: Dictionary(grouping: events, by: \.sceneHash), segments: [outline.scenes[0].contentHash: .init(segments: [segment])],
            eventGraph: graph, plotThreadAnalysis: threads, characters: [person])
        return (doc, snapshot, ContinuityCandidate.prepare(snapshot: story, before: source.utf16.count))
    }
    private func project(_ value: (ProjectDocumentSnapshot, KnowledgeSnapshot, [ContinuityCandidate])) async throws -> FictionReviewProjection {
        try await FictionReviewProjection.prepare(value.0, snapshot: value.1, snapshotOrigin: value.0.identity, candidates: value.2)
    }
    func testActualAtomicThreadAndSegmentProducersAreOriginalBackedNeutralAndOrdered() async throws {
        let value = fixture(cyclic: true), result = try await project(value)
        XCTAssertEqual(Set(result.issues.map(\.category)), [.characters, .timeline, .openThreads, .structure])
        XCTAssertEqual(result.counts[.openThreads], 1); XCTAssertEqual(result.counts[.structure], 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.issues.allSatisfy { $0.severity == .note && !$0.evidence.isEmpty })
        XCTAssertTrue(result.issues.filter(\.requiresJudging).count >= 2)
        for issue in result.issues {
            XCTAssertEqual(issue.identity, value.0.identity)
            XCTAssertEqual(issue.revision, value.1.storyKnowledge?.sourceRevision)
            for anchor in issue.evidence {
                XCTAssertEqual(anchor.documentID, value.0.identity.key.documentID)
                let start = try XCTUnwrap(anchor.utf16Hint)
                XCTAssertTrue((value.0.body as NSString).substring(with: NSRange(location: start, length: anchor.quote.utf16.count)).utf16.elementsEqual(anchor.quote.utf16))
            }
        }
    }
    func testIdenticalReindexDeduplicatesAndOffsetMovesKeepLogicalIssueIdentity() async throws {
        let first = fixture(), original = try await project(first)
        let duplicated = try await FictionReviewProjection.prepare(first.0, snapshot: first.1, snapshotOrigin: first.0.identity,
            candidates: Array((first.2 + first.2).reversed()))
        XCTAssertEqual(duplicated.issues, original.issues)
        let moved = fixture(prefix: "앞부분 기록.\n", identity: .init(key: first.0.identity.key, generation: first.0.identity.generation + 1))
        let next = try await project(moved)
        XCTAssertEqual(next.issues.map(\.id), original.issues.map(\.id))
        XCTAssertNotEqual(next.issues.first?.evidence.first?.utf16Hint, original.issues.first?.evidence.first?.utf16Hint)
    }
    func testUnknownTimeResolvedThreadsAndWeakUncertainSegmentsStayQuiet() async throws {
        let value = fixture(knownTime: false, confidence: 0.79, resolved: true), result = try await project(value)
        XCTAssertTrue(result.issues.isEmpty)
        for confidence in [Double.nan, Double.infinity, -1, 2] {
            let result = try await project(fixture(knownTime: false, confidence: confidence, resolved: true))
            XCTAssertTrue(result.issues.isEmpty)
        }
    }
    func testOriginalFreeSnapshotCannotTurnSummariesIntoIssues() async throws {
        let value = fixture(knownTime: false, confidence: 0.1, eventsHaveOriginals: false)
        let result = try await project(value)
        XCTAssertTrue(result.issues.isEmpty)
    }
    func testWrongOriginScopeRevisionModeAndCancellationCannotPublishIssues() async throws {
        let value = fixture()
        let foreign = try await FictionReviewProjection.prepare(value.0, snapshot: value.1,
            snapshotOrigin: .init(key: value.0.identity.key, generation: value.0.identity.generation + 1), candidates: value.2)
        XCTAssertTrue(foreign.issues.isEmpty)
        for mode: WritingMode in [.fiction, .general] {
            let changed = ProjectDocumentSnapshot(identity: value.0.identity, title: "Changed", body: value.0.body + "추가", kind: .manuscript, mode: mode, userData: [:])
            let refused = try await FictionReviewProjection.prepare(changed, snapshot: value.1, snapshotOrigin: changed.identity, candidates: value.2)
            XCTAssertTrue(refused.issues.isEmpty)
        }
        let foreignScope = StoryMemoryScope.project(projectID: WritingProjectID(), documentID: value.0.identity.key.documentID)
        let wrong = KnowledgeSnapshot(entryID: value.0.identity.key.documentID.rawValue, outline: value.1.outline, summariesByHash: [:],
            storyKnowledge: .init(scope: foreignScope, source: value.0.body, facts: [], entities: .init(characters: [person])))
        let rejected = try await FictionReviewProjection.prepare(value.0, snapshot: wrong, snapshotOrigin: value.0.identity, candidates: value.2)
        XCTAssertTrue(rejected.issues.isEmpty)
        let raw = fixture(prefix: "한\n")
        let canonical = ProjectDocumentSnapshot(identity: raw.0.identity, title: raw.0.title, body: raw.0.body.precomposedStringWithCanonicalMapping,
            kind: .manuscript, mode: .fiction, userData: [:])
        let unicode = try await FictionReviewProjection.prepare(canonical, snapshot: raw.1, snapshotOrigin: raw.0.identity, candidates: raw.2)
        XCTAssertTrue(unicode.issues.isEmpty)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await self.project(value) }
        do { _ = try await task.value; XCTFail("Cancelled projection must refuse") } catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
    }
    func testPrivateIssueFactoryCannotEscalateUnjudgedOrForeignCandidates() throws {
        let value = fixture(), candidate = try XCTUnwrap(value.2.first { $0.kind == .knowledgeLeak })
        let context = try XCTUnwrap(ReviewOriginalContext.prepare(value.0, snapshot: value.1, origin: value.0.identity))
        let unjudged = ReviewIssue.prepare(logicalID: "unjudged", category: .characters, severity: .review,
            title: "확인", message: "제안", evidence: candidate.evidence, candidate: candidate, context: context)
        XCTAssertNil(unjudged, "Only a complete bounded judge may promote a semantic candidate")
        let prose = ReviewIssue.prepare(logicalID: "prose", category: .characters, severity: .review,
            title: "확인", message: "제안", evidence: candidate.evidence, context: context)
        XCTAssertNil(prose, "Two original quotes alone cannot promote arbitrary explanation prose")
        let foreign = fixture(identity: .init(key: .init(projectID: WritingProjectID(), documentID: value.0.identity.key.documentID), generation: 1))
        let otherContext = try XCTUnwrap(ReviewOriginalContext.prepare(foreign.0, snapshot: foreign.1, origin: foreign.0.identity))
        let crossProject = ReviewIssue.prepare(logicalID: "foreign", category: .characters, title: "확인", message: "제안",
            evidence: candidate.evidence, candidate: candidate, context: otherContext)
        XCTAssertNil(crossProject)
    }
    func testOriginalFactoryRejectsRelabeledCandidatesAndSurrogateHalfEvidence() throws {
        let value = fixture(prefix: "😀\n"), candidate = try XCTUnwrap(value.2.first { $0.kind == .knowledgeLeak })
        let context = try XCTUnwrap(ReviewOriginalContext.prepare(value.0, snapshot: value.1, origin: value.0.identity))
        let relabeled = ReviewIssue.prepare(logicalID: "wrong-category", category: .dialogue, title: "확인", message: "제안",
            evidence: candidate.evidence, candidate: candidate, context: context)
        XCTAssertNil(relabeled)
        let offset = (value.0.body as NSString).range(of: "😀").location
        let half = ReviewIssue.prepare(logicalID: "surrogate", category: .structure, title: "확인", message: "제안",
            evidence: [.init(documentID: value.0.identity.key.documentID, quote: "�", utf16Hint: offset)], context: context)
        XCTAssertNil(half, "UTF16 slicing repair must not manufacture original evidence")
    }
    func testLogicalDuplicateKeepsEarliestOriginalPairIndependentOfInputOrder() async throws {
        let value = fixture(prefix: "민준은 알고 있었다.\n민준은 모르고 있었다.\n")
        let early = try XCTUnwrap(value.2.first { $0.kind == .knowledgeLeak })
        let scope = StoryMemoryScope.project(projectID: value.0.identity.key.projectID, documentID: value.0.identity.key.documentID)
        let lateFacts = ["민준은 알고 있었다.", "민준은 모르고 있었다."].enumerated().map { index, quote -> StoryFact in
            let offset = (value.0.body as NSString).range(of: quote, options: .backwards).location
            return .init(derivedID: "late-\(index)", scope: scope,
                content: .characterKnowledge(.init(characterID: person.id, fact: "문을 열기", stance: index == 0 ? .knows : .unaware)),
                evidence: .init(documentID: scope.documentID, quote: quote, utf16Hint: offset), discourseRange: offset..<(offset + quote.utf16.count),
                storyInterval: .point(.init(timelineID: timeline, tick: 1)), confidence: 0.9, origin: .deterministic(ruleID: "fixture"))
        }
        let later = StoryKnowledgeSnapshot(scope: scope, source: value.0.body, facts: lateFacts, entities: .init(characters: [person]))
        let late = try XCTUnwrap(ContinuityCandidate.prepare(snapshot: later, before: value.0.body.utf16.count).first)
        XCTAssertEqual(early.id, late.id)
        let a = try await FictionReviewProjection.prepare(value.0, snapshot: value.1, snapshotOrigin: value.0.identity, candidates: [early, late])
        let b = try await FictionReviewProjection.prepare(value.0, snapshot: value.1, snapshotOrigin: value.0.identity, candidates: [late, early])
        let first = a.issues.first { $0.candidate?.id == early.id }, second = b.issues.first { $0.candidate?.id == early.id }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.evidence.first?.utf16Hint, early.evidence.first?.utf16Hint)
    }
    func testInputBudgetRefusesPartialAuthority() async throws {
        let value = fixture(), candidate = try XCTUnwrap(value.2.first)
        let result = try await FictionReviewProjection.prepare(value.0, snapshot: value.1, snapshotOrigin: value.0.identity,
            candidates: Array(repeating: candidate, count: 8193))
        XCTAssertTrue(result.issues.isEmpty); XCTAssertFalse(result.isComplete)
    }
    func testActualLegacyDeadSpeakerAndHonorificProducersRemainEvidenceBacked() async throws {
        let sources = ["# 사건\n민준은 사망했다.\n# 현재\n민준이 말했다. \"돌아왔어요.\"",
            "# 현재\n민준이 말했다. \"하나요.\"\n서연이 말했다. \"응.\"\n민준이 말했다. \"둘요.\"\n서연이 말했다. \"응.\"\n민준이 말했다. \"셋요.\"\n서연이 말했다. \"응.\"\n민준이 말했다. \"넷이야.\""]
        for (index, source) in sources.enumerated() {
            let identity = ProjectRuntimeIdentity(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1)
            let scope = StoryMemoryScope.project(projectID: identity.key.projectID, documentID: identity.key.documentID), outline = DocumentOutline.parse(source)
            let hash = outline.scenes[0].contentHash
            let events: [String: [StoryEvent]] = index == 0 ? [hash: [.init(sceneHash: hash, participants: [person.id], summary: "사망 기록", importance: 5,
                deltas: [.init(characterID: person.id, field: .vitality, value: "사망", sceneHash: hash)], quote: "민준은 사망했다.")]] : [:]
            let snapshot = KnowledgeSnapshot(entryID: identity.key.documentID.rawValue, outline: outline, summariesByHash: [:],
                storyKnowledge: .init(scope: scope, source: source, facts: [], entities: .init(characters: [person, other])), events: events,
                utterances: DialogueAttribution.utterances(in: source, cards: [person, other]), characters: [person, other])
            let candidates = ContinuityCandidate.prepare(snapshot: snapshot,
                warnings: ConsistencyChecker.check(snapshot: snapshot, characters: [person, other], source: source), scope: scope, source: source)
            XCTAssertEqual(candidates.count, 1)
            let document = ProjectDocumentSnapshot(identity: identity, title: "Legacy", body: source, kind: .manuscript, mode: .fiction, userData: [:])
            let result = try await FictionReviewProjection.prepare(document, snapshot: snapshot, snapshotOrigin: identity, candidates: candidates)
            let issue = try XCTUnwrap(result.issues.first)
            XCTAssertEqual(result.issues.count, 1); XCTAssertEqual(issue.category, index == 0 ? .continuity : .dialogue)
            XCTAssertEqual(issue.severity, .review); XCTAssertFalse(issue.requiresJudging)
            XCTAssertEqual(issue.evidence.count, index == 0 ? 2 : 4)
        }
    }
}
