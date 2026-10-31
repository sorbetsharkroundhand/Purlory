import XCTest
@testable import PurloryFoundation
@testable import PurloryCore
@testable import PurloryIntelligence
@testable import PurloryWorkspaceUI

final class SourceIndexTests: XCTestCase {
    func testIndexedSearchMatchesLiteralOracleAcrossUnicodeAliasesScopesAndCursorBounds() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let documents = [
            "민준은 needle 앞에 있었다. CAFÉ cafe\u{301} Straße STRASSE ſame.\n",
            "# One\n## Here\n민준은 ‘NEEDLE’을 찾았다. 김민준과 함께. 🙂 가나다.\n## Later\nneedle은 나중.\n",
            "가나다 가나다 needle. 따옴표 \"AND\" %_* 괄호 (abc).\n",
        ].enumerated().map { WritingDocument(id: WritingDocumentID(), title: "Document \($0.offset)", body: $0.element, kind: .manuscript) }
        var project = WritingProject(id: WritingProjectID(), title: "Unicode", mode: .fiction, documents: documents)
        project.userData[WriterDocumentData.key(for: documents[1].id)] = try WriterDocumentData(documentID: documents[1].id,
            characters: [CharacterCard(name: "민준은", aliases: "김민준")]).encoded()
        try await store.save(project)
        let index = ProjectSourceIndex(store: store), origin = documents[1].id
        let cursor = (documents[1].body as NSString).range(of: "## Later").location
        for query in ["민준은", "김민준", "민준", "needle", "café", "cafe\u{301}", "STRASSE", "same", "가나다", "가나다", "🙂", "\"AND\"", "%_*", "(abc)"] {
            for scope in SourceSearchScope.allCases {
                for purpose in [SourceSearchPurpose.inspection, .beforeCursor] {
                    let oracle = try SourceSearch.results(query: query, in: project, origin: origin, cursor: cursor, scope: scope, purpose: purpose)
                    let indexed = try await SourceSearch.results(query: query, in: project, origin: origin, cursor: cursor, scope: scope, purpose: purpose, index: index)
                    XCTAssertEqual(indexed, oracle, "\(query), \(scope), \(purpose)")
                }
            }
            let names = await ProjectSearch.results(query: query, in: project, index: index)
            XCTAssertEqual(names, ProjectSearch.results(query: query, in: project))
        }
        let repeated = await index.lastPreparedDocumentCount
        XCTAssertEqual(repeated, 0, "Repeated searches must reuse source versions and outlines")
        project.documents[0].body += " New needle."
        _ = try await index.prepare(terms: ["needle"], in: project)
        let changed = await index.lastPreparedDocumentCount
        XCTAssertEqual(changed, 1)
        await index.setMemoryPressurePaused(true)
        let paused = try await SourceSearch.results(query: "needle", in: project, origin: origin,
            cursor: cursor, scope: .project, index: index)
        XCTAssertEqual(paused, try SourceSearch.results(query: "needle", in: project, origin: origin, cursor: cursor, scope: .project))
        await index.setMemoryPressurePaused(false)
        project.trashedDocumentIDs.insert(documents[2].id)
        let remaining = try await index.prepare(terms: ["needle"], in: project)
        XCTAssertFalse(remaining.candidates["needle"]?.contains(documents[2].id) ?? true)
        let rebuilt = await index.lastPreparedDocumentCount
        XCTAssertEqual(rebuilt, 2, "Pressure shedding must release prepared source/outline values")
    }

    func testUnavailableIndexFallsBackWithoutLosingOriginalEvidence() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let document = WritingDocument(id: WritingDocumentID(), title: "Unsaved", body: "# Scene\nneedle and original evidence", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Not yet persisted", mode: .general, documents: [document])
        let result = try await SourceSearch.results(query: "needle", in: project, origin: document.id, cursor: 0, scope: .project,
            index: ProjectSourceIndex(store: store))
        XCTAssertEqual(result, try SourceSearch.results(query: "needle", in: project, origin: document.id, cursor: 0, scope: .project))
        XCTAssertEqual(result.count, 1)
    }

    func testCancelledIndexPreparationDoesNotBecomeSearchResults() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = WritingDocument(id: WritingDocumentID(), title: "Draft", body: "needle", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Project", mode: .general, documents: [document])
        let index = ProjectSourceIndex(store: ProjectStore(root: root))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SourceSearch.results(query: "needle", in: project, origin: document.id, cursor: 0, scope: .project, index: index)
        }
        do { _ = try await task.value; XCTFail("Cancelled search published") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTrigramCandidatesIncludeExactKoreanSubstringsAndUnsavedChanges() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let a = WritingDocument(id: WritingDocumentID(), title: "A", body: "민준은 문을 열었다.", kind: .manuscript)
        let b = WritingDocument(id: WritingDocumentID(), title: "B", body: "조용한 아침이었다.", kind: .manuscript)
        var project = WritingProject(id: WritingProjectID(), title: "Fixture", mode: .fiction, documents: [a, b])
        try await store.save(project)
        let index = ProjectSourceIndex(store: store)
        let first = try await index.prepare(terms: ["민준은", "아침이"], in: project)
        XCTAssertEqual(first.candidates["민준은"], [a.id])
        XCTAssertEqual(first.candidates["아침이"], [b.id])
        XCTAssertEqual(first.outlines[a.id], DocumentOutline.parse(a.body))
        project.documents[0].source = DocumentSource(chunks: ["다른 원고."])
        project.documents[1].source = DocumentSource(chunks: ["민준은 ", "돌아왔다."])
        let updated = try await index.prepare(terms: ["민준은"], in: project)
        XCTAssertEqual(updated.candidates["민준은"], [b.id])
        let durable = try await store.load(id: project.id)
        XCTAssertEqual(durable.documents[0].body, a.body, "Search must not save the manuscript")
        XCTAssertEqual(durable.documents[1].body, b.body)
    }
}
