@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class SourceSearchTests: XCTestCase {
    private func fixture() -> WritingProject {
        WritingProject(id: WritingProjectID(), title: "Draft", mode: .general, documents: [
            WritingDocument(id: WritingDocumentID(), title: "Earlier", body: "needle before", kind: .note),
            WritingDocument(id: WritingDocumentID(), title: "Current", body:
                "# Part\n## One\n### Here\n😀 needle here.\n### Nearby\nneedle nearby.\n## Two\nneedle future.\n## One\nneedle repeated heading.", kind: .manuscript),
            WritingDocument(id: WritingDocumentID(), title: "Later", body: "needle later", kind: .manuscript)])
    }

    func testScopesRankingAndTrashAreDeterministic() throws {
        var p = fixture(); let origin = p.documents[1].id
        let cursor = (p.documents[1].body as NSString).range(of: "here.").location
        func hits(_ scope: SourceSearchScope) throws -> [SourceSearchHit] {
            try SourceSearch.results(query: "needle", in: p, origin: origin, cursor: cursor, scope: scope)
        }
        XCTAssertEqual(try hits(.here).count, 1)
        XCTAssertEqual(try hits(.chapter).map(\.matchedText), ["needle", "needle"])
        let all = try hits(.project)
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all, try hits(.project))
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        for hit in all {
            let document = try XCTUnwrap(p.documents.first { $0.id == hit.documentID })
            XCTAssertTrue(document.body.contains(hit.evidence.quote))
            XCTAssertEqual(hit.reason, .literal)
        }
        p.trashedDocumentIDs.insert(p.documents[2].id)
        XCTAssertEqual(try hits(.project).count, 5)
    }

    func testBeforeCursorExcludesFutureDocumentsAndQuoteContextIncludingSplitMatch() throws {
        let p = fixture(); let d = p.documents[1]
        let cursor = NSMaxRange((d.body as NSString).range(of: "needle here"))
        let hits = try SourceSearch.results(query: "needle", in: p, origin: d.id,
            cursor: cursor, scope: .project, purpose: .beforeCursor)
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { !$0.evidence.quote.contains("nearby") && !$0.evidence.quote.contains("future") })
        XCTAssertEqual(hits.last?.evidence.quote.hasSuffix("here"), true)
        let split = (d.body as NSString).range(of: "needle").location + 3
        XCTAssertEqual(try SourceSearch.results(query: "needle", in: p, origin: d.id,
            cursor: split, scope: .here, purpose: .beforeCursor).count, 0)
    }

    func testOnlyExplicitUnambiguousAliasesExpandAndLiteralRanksFirst() throws {
        var p = fixture(); let d = p.documents[1]
        p.documents[1].body = "미나는 돌아왔다.\n민아가 떠났다.\n추정은 기다렸다."
        var data = WriterDocumentData(documentID: d.id, characters: [
            CharacterCard(name: "미나", aliases: "민아"),
            CharacterCard(name: "미나", aliases: "추정", autoRegistered: true)])
        p.userData[WriterDocumentData.key(for: d.id)] = try data.encoded()
        let hits = try SourceSearch.results(query: "미나", in: p, origin: d.id, cursor: 0, scope: .project)
        XCTAssertEqual(hits.map(\.matchedText), ["미나", "민아"])
        XCTAssertEqual(hits.map(\.reason), [.literal, .confirmedName])
        data.characters.append(CharacterCard(name: "다른 사람", aliases: "미나"))
        p.userData[WriterDocumentData.key(for: d.id)] = try data.encoded()
        XCTAssertEqual(try SourceSearch.results(query: "미나", in: p, origin: d.id, cursor: 0, scope: .project).count, 1)
        p.userData[WriterDocumentData.key(for: d.id)] = Data("corrupt".utf8)
        XCTAssertEqual(try SourceSearch.results(query: "미나", in: p, origin: d.id, cursor: 0, scope: .project).count, 1)
    }

    func testInvalidScopeEmptyQueryAndOutputLimit() throws {
        let p = fixture(); let d = p.documents[1]
        XCTAssertTrue(try SourceSearch.results(query: "needle", in: p, origin: WritingDocumentID(), cursor: 0, scope: .project).isEmpty)
        XCTAssertTrue(try SourceSearch.results(query: " \n ", in: p, origin: d.id, cursor: 0, scope: .project).isEmpty)
        XCTAssertEqual(try SourceSearch.results(query: "needle", in: p, origin: d.id, cursor: 0, scope: .project, limit: 2).count, 2)
    }

    func testExactAnchorsUseRevisionBoundHintOrUniqueQuoteAndOtherwiseStayStale() {
        let id = WritingDocumentID(), body = "😀 needle\nneedle"
        let hint = (body as NSString).range(of: "needle", options: .backwards).location
        let anchor = EvidenceAnchor(documentID: id, quote: "needle", utf16Hint: hint)
        let revision = DocumentOutline.stableHash(body)
        XCTAssertEqual(SourceAnchor.exactRange(for: anchor, in: body, revision: revision)?.location, hint)
        XCTAssertNil(SourceAnchor.exactRange(for: anchor, in: "new\n" + body, revision: revision))
        XCTAssertEqual(SourceAnchor.exactRange(for: anchor, in: "new 😀 needle", revision: revision)?.location, 7)
        XCTAssertNil(SourceAnchor.exactRange(for: anchor, in: "unrelated replacement", revision: revision))
    }

    func testNearbyOccurrencesKeepDistinctIdentityAndOverlappingQuotesBecomeStale() throws {
        var p = fixture(); let id = p.documents[1].id
        p.documents[1].body = "needle needle"
        let hits = try SourceSearch.results(query: "needle", in: p, origin: id, cursor: 0, scope: .project)
        XCTAssertEqual(Set(hits.filter { $0.documentID == id }.map(\.id)).count, 2)
        let anchor = EvidenceAnchor(documentID: id, quote: "aa", utf16Hint: 0)
        XCTAssertNil(SourceAnchor.exactRange(for: anchor, in: "aaa", revision: "old"))
    }

    func testChapterSearchFindsLiteralAcrossDerivedSegmentBoundary() throws {
        var p = fixture(); let id = p.documents[1].id
        p.documents[1].body = String(repeating: "a", count: 1500) + "b"
        XCTAssertEqual(try SourceSearch.results(query: "ab", in: p, origin: id,
            cursor: 0, scope: .chapter).count, 1)
    }

    func testCancellationStopsExplicitSearch() async {
        let p = fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SourceSearch.results(query: "needle", in: p, origin: p.documents[0].id, cursor: 0, scope: .project)
        }
        do { _ = try await task.value; XCTFail("Cancellation must be observed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
