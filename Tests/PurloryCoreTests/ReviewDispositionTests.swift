@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ReviewDispositionTests: XCTestCase {
    private let person = CharacterCard(name: "민준"), timeline = UUID()
    private func fixture() async throws -> LegacyBoundaryFixture {
        let f = try await LegacyBoundaryFixture(mode: .fiction)
        f.session.updateSelectedDocumentBody("# 기록\n민준은 문을 알고 있었다.\n민준은 문을 모르고 있었다.\n")
        try ProjectWriterEditing.perform(.character(person), in: f.session, identity: try XCTUnwrap(f.session.runtimeIdentity))
        return f
    }
    private func issue(in session: ProjectSession) async throws -> ReviewIssue {
        let document = try XCTUnwrap(session.selectedDocumentSnapshot)
        let scope = StoryMemoryScope.project(projectID: document.identity.key.projectID, documentID: document.identity.key.documentID)
        let facts = ["민준은 문을 알고 있었다.", "민준은 문을 모르고 있었다."].enumerated().map { index, quote -> StoryFact in
            let offset = (document.body as NSString).range(of: quote).location
            return .init(derivedID: "fact-\(index)", scope: scope,
                content: .characterKnowledge(.init(characterID: person.id, fact: "문", stance: index == 0 ? .knows : .unaware)),
                evidence: .init(documentID: scope.documentID, quote: quote, utf16Hint: offset), discourseRange: offset..<(offset + quote.utf16.count),
                storyInterval: .point(.init(timelineID: timeline, tick: 1)), confidence: 0.9, origin: .deterministic(ruleID: "fixture"))
        }
        let story = StoryKnowledgeSnapshot(scope: scope, source: document.body, facts: facts, entities: .init(characters: [person]))
        let snapshot = KnowledgeSnapshot(entryID: scope.documentID.rawValue, outline: DocumentOutline.parse(document.body), summariesByHash: [:], storyKnowledge: story)
        let result = try await FictionReviewProjection.prepare(document, snapshot: snapshot, snapshotOrigin: document.identity,
            candidates: ContinuityCandidate.prepare(snapshot: story, before: document.body.utf16.count))
        return try XCTUnwrap(result.issues.first)
    }
    private func writer(_ session: ProjectSession) throws -> WriterDocumentData {
        let document = try XCTUnwrap(session.selectedDocumentSnapshot)
        return try .decode(document.userData[WriterDocumentData.key(for: document.identity.key.documentID)], documentID: document.identity.key.documentID)
    }
    func testIntentionalPersistsReloadsAndSuppressesIdenticalReindexWithoutChangingBodyOrStyle() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let unrelated = WriterDecision(kind: .confirmed, targetID: "unrelated", statement: "별도 작가 설정")
        try ProjectWriterEditing.perform(.decision(unrelated), in: f.session, identity: try XCTUnwrap(f.session.runtimeIdentity))
        let style = Data("retain-style-bytes".utf8)
        try f.session.updateUserData(style, for: WritingStyleRepository.key, identity: try XCTUnwrap(f.session.runtimeIdentity))
        let original = try XCTUnwrap(f.session.selectedDocumentSnapshot), value = try await issue(in: f.session)
        try ReviewDispositionService.record(.intentional, issue: value, in: f.session, identity: value.identity)
        let current = try XCTUnwrap(f.session.selectedDocumentSnapshot), index = try ReviewDispositionIndex.load(current)
        XCTAssertEqual(index.state(for: value), .intentional)
        let record = try XCTUnwrap(index.records.first { $0.targetID == value.id })
        XCTAssertEqual(record.kind, .intentional); XCTAssertEqual(record.evidence, value.evidence)
        XCTAssertFalse(record.statement.isEmpty)
        XCTAssertEqual(try writer(f.session).characters, [person]); XCTAssertTrue(try writer(f.session).decisions.contains(unrelated))
        XCTAssertEqual(current.userData[WritingStyleRepository.key], style)
        XCTAssertTrue(current.body.utf16.elementsEqual(original.body.utf16))
        try await f.session.flush()
        let loaded = try await f.store.load(id: current.identity.key.projectID)
        let durable = try WriterDocumentData.decode(loaded.userData[WriterDocumentData.key(for: current.identity.key.documentID)], documentID: current.identity.key.documentID)
        XCTAssertTrue(durable.decisions.contains(record)); XCTAssertTrue(durable.decisions.contains(unrelated))
        let reindexed = try await issue(in: f.session)
        XCTAssertEqual(reindexed.id, value.id); XCTAssertEqual(try ReviewDispositionIndex.load(current).state(for: reindexed), .intentional)
        let before = f.session.runtimeIdentity
        try ReviewDispositionService.record(.intentional, issue: reindexed, in: f.session, identity: reindexed.identity)
        XCTAssertEqual(f.session.runtimeIdentity, before, "An identical explicit choice is a true no-op")
        XCTAssertEqual(try writer(f.session).decisions.filter { $0.targetID == value.id }.count, 1)
    }
    func testResolvedAndExplicitRestorePreserveUnrelatedDecisionsEvenAfterOriginalBecomesStale() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let unrelated = WriterDecision(kind: .intentional, targetID: "other", statement: "남겨 둘 기록")
        try ProjectWriterEditing.perform(.decision(unrelated), in: f.session, identity: try XCTUnwrap(f.session.runtimeIdentity))
        let value = try await issue(in: f.session)
        try ReviewDispositionService.record(.resolved, issue: value, in: f.session, identity: value.identity)
        let document = try XCTUnwrap(f.session.selectedDocumentSnapshot), index = try ReviewDispositionIndex.load(document)
        XCTAssertEqual(index.state(for: value), .resolved)
        let record = try XCTUnwrap(index.records.first { $0.targetID == value.id })
        XCTAssertEqual(record.kind, .dismissed)
        f.session.updateSelectedDocumentBody("# 바뀐 원고\n이전 인용은 더 이상 없다.")
        let identity = try XCTUnwrap(f.session.runtimeIdentity)
        try ReviewDispositionService.restore(decisionID: record.id, targetID: value.id, in: f.session, identity: identity)
        let restored = try XCTUnwrap(f.session.selectedDocumentSnapshot)
        XCTAssertEqual(try ReviewDispositionIndex.load(restored).state(for: value), .active)
        XCTAssertEqual(try writer(f.session).decisions, [unrelated])
        XCTAssertEqual(restored.body, "# 바뀐 원고\n이전 인용은 더 이상 없다.")
        let bytes = restored.userData
        XCTAssertThrowsError(try ReviewDispositionService.restore(decisionID: unrelated.id, targetID: value.id, in: f.session, identity: try XCTUnwrap(f.session.runtimeIdentity)))
        XCTAssertEqual(f.session.activeProject?.userData, bytes)
    }
    func testABAAndSameDocumentIDInAnotherProjectCannotReviveAnOldAction() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let value = try await issue(in: f.session), original = try XCTUnwrap(f.session.selectedDocumentSnapshot)
        _ = f.session.createDocument(title: "Other"); f.session.selectDocument(original.identity.key.documentID)
        let current = try XCTUnwrap(f.session.runtimeIdentity), bytes = f.session.activeProject?.userData
        XCTAssertNotEqual(current, value.identity)
        XCTAssertThrowsError(try ReviewDispositionService.record(.intentional, issue: value, in: f.session, identity: value.identity))
        XCTAssertThrowsError(try ReviewDispositionService.record(.intentional, issue: value, in: f.session, identity: current))
        XCTAssertEqual(f.session.activeProject?.userData, bytes)
        var foreign = WritingProject(id: WritingProjectID(), title: "Foreign", mode: .fiction,
            documents: [.init(id: original.identity.key.documentID, title: original.title, body: original.body, kind: .manuscript)])
        foreign.userData = f.session.activeProject?.userData ?? [:]
        try await f.session.saveAndActivate(foreign)
        let other = try XCTUnwrap(f.session.runtimeIdentity)
        XCTAssertThrowsError(try ReviewDispositionService.record(.intentional, issue: value, in: f.session, identity: other))
        let next = try await issue(in: f.session)
        XCTAssertNotEqual(next.id, value.id)
        XCTAssertEqual(try ReviewDispositionIndex.load(try XCTUnwrap(f.session.selectedDocumentSnapshot)).state(for: value), .active)
    }
    func testCorruptAndUnsupportedWriterDataCannotBeReplacedByAReviewDecision() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let document = try XCTUnwrap(f.session.selectedDocumentSnapshot), key = WriterDocumentData.key(for: document.identity.key.documentID)
        var future = WriterDocumentData(documentID: document.identity.key.documentID, characters: [person]); future.schemaVersion = 2
        for bytes in [Data("malformed".utf8), try JSONEncoder().encode(future)] {
            try f.session.updateUserData(bytes, for: key, identity: try XCTUnwrap(f.session.runtimeIdentity))
            let value = try await issue(in: f.session), current = try XCTUnwrap(f.session.selectedDocumentSnapshot)
            XCTAssertThrowsError(try ReviewDispositionIndex.load(current))
            XCTAssertThrowsError(try ReviewDispositionService.record(.intentional, issue: value, in: f.session, identity: value.identity))
            XCTAssertEqual(f.session.selectedDocumentSnapshot?.userData[key], bytes)
            XCTAssertTrue(f.session.selectedDocumentSnapshot?.body.utf16.elementsEqual(document.body.utf16) == true)
        }
    }

    func testOffsetMoveAndExplicitChoiceChangeRetainRecordIdentityAndWriterNote() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let original = try await issue(in: f.session)
        try ReviewDispositionService.record(.intentional, issue: original, in: f.session,
            identity: original.identity, statement: "  복선으로 남긴 모순  ")
        let saved = try XCTUnwrap(ReviewDispositionIndex.load(try XCTUnwrap(f.session.selectedDocumentSnapshot)).records.first)
        f.session.updateSelectedDocumentBody("앞에 추가한 문단입니다.\n\n" + (f.session.selectedDocument?.body ?? ""))
        let moved = try await issue(in: f.session)
        XCTAssertEqual(original.id, moved.id)
        XCTAssertNotEqual(original.evidence, moved.evidence)
        XCTAssertEqual(try ReviewDispositionIndex.load(try XCTUnwrap(f.session.selectedDocumentSnapshot)).state(for: moved), .intentional)
        let before = f.session.activeProject?.userData
        XCTAssertThrowsError(try ReviewDispositionService.record(.resolved, issue: original, in: f.session, identity: moved.identity))
        XCTAssertThrowsError(try ReviewDispositionService.record(.resolved, issue: moved, in: f.session, identity: moved.identity, statement: " \n "))
        XCTAssertEqual(f.session.activeProject?.userData, before)
        try ReviewDispositionService.record(.resolved, issue: moved, in: f.session, identity: moved.identity)
        let index = try ReviewDispositionIndex.load(try XCTUnwrap(f.session.selectedDocumentSnapshot))
        let changed = try XCTUnwrap(index.records.first)
        XCTAssertEqual(index.state(for: moved), .resolved)
        XCTAssertEqual(changed.id, saved.id); XCTAssertEqual(changed.createdAt, saved.createdAt)
        XCTAssertEqual(changed.statement, "복선으로 남긴 모순")
        XCTAssertEqual(changed.evidence, moved.evidence); XCTAssertEqual(index.records.count, 1)
    }

    func testLatestExplicitRecordWinsWithoutDeletingOlderWriterDecisions() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let value = try await issue(in: f.session)
        var old = WriterDecision(kind: .intentional, targetID: value.id, statement: "이전 판단")
        old.createdAt = Date(timeIntervalSince1970: 1)
        var newer = WriterDecision(kind: .dismissed, targetID: value.id, statement: "검토를 마쳤음")
        newer.createdAt = Date(timeIntervalSince1970: 2)
        for record in [newer, old] {
            try ProjectWriterEditing.perform(.decision(record), in: f.session, identity: try XCTUnwrap(f.session.runtimeIdentity))
        }
        let index = try ReviewDispositionIndex.load(try XCTUnwrap(f.session.selectedDocumentSnapshot))
        XCTAssertEqual(index.state(for: value), .resolved)
        XCTAssertEqual(index.records, [newer, old])
    }
}
