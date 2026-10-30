@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ProjectSearchTests: XCTestCase {
    func testSearchReturnsOnlyVisibleActiveProjectDocumentsInDocumentOrder() {
        let first = WritingDocument(
            id: WritingDocumentID(), title: "Opening", body: "Nothing here.", kind: .manuscript)
        let second = WritingDocument(
            id: WritingDocumentID(), title: "Middle", body: "Before NEEDLE after.", kind: .manuscript)
        let third = WritingDocument(
            id: WritingDocumentID(), title: "Needle Notes", body: "Reference", kind: .note)
        let trashed = WritingDocument(
            id: WritingDocumentID(), title: "Discarded", body: "needle", kind: .reference)
        let project = WritingProject(
            id: WritingProjectID(),
            title: "Project A",
            mode: .fiction,
            documents: [first, second, third, trashed],
            trashedDocumentIDs: [trashed.id])
        let otherProject = WritingProject(
            id: WritingProjectID(),
            title: "Project B",
            mode: .general,
            documents: [
                WritingDocument(
                    id: WritingDocumentID(), title: "Other", body: "needle", kind: .manuscript)
            ])

        let results = ProjectSearch.results(query: "needle", in: project)

        XCTAssertEqual(results.map(\.documentID), [second.id, third.id])
        XCTAssertTrue(results.allSatisfy { $0.projectID == project.id })
        XCTAssertFalse(results.contains { $0.projectID == otherProject.id })
        XCTAssertFalse(results.contains { $0.documentID == trashed.id })
    }

    func testSearchUsesFirstCaseInsensitiveLiteralMatchForSnippet() throws {
        let document = WritingDocument(
            id: WritingDocumentID(),
            title: "Chapter",
            body: "Before NEEDLE after needle.",
            kind: .manuscript)
        let project = WritingProject(
            id: WritingProjectID(),
            title: "Novel",
            mode: .fiction,
            documents: [document])

        let result = try XCTUnwrap(ProjectSearch.results(query: "needle", in: project).first)

        XCTAssertEqual(result.title, "Chapter")
        XCTAssertEqual(result.snippet, "Before NEEDLE after needle.")
        XCTAssertEqual(result.query, "needle")
    }

    func testWhitespaceOnlySearchReturnsNoResults() {
        let project = WritingProject(
            id: WritingProjectID(),
            title: "Draft",
            mode: .general,
            documents: [
                WritingDocument(
                    id: WritingDocumentID(), title: "Page", body: "Words", kind: .manuscript)
            ])

        XCTAssertTrue(ProjectSearch.results(query: "  \n ", in: project).isEmpty)
    }
}
