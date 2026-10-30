@testable import PurloryIntelligence
import XCTest
import PurloryCore

final class WritingProjectTests: XCTestCase {
    func testMissingTrashFieldDecodesAsEmptyAndRoundTripsTrash() throws {
        let document = WritingDocument(
            id: WritingDocumentID(), title: "Draft", body: "body", kind: .manuscript)
        let legacyJSON = """
        {"id":{"rawValue":"00000000-0000-0000-0000-000000000001"},"title":"Old","mode":"general","documents":[]}
        """
        let decoded = try JSONDecoder().decode(WritingProject.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.trashedDocumentIDs, [])

        let project = WritingProject(
            id: WritingProjectID(), title: "New", mode: .general,
            documents: [document], trashedDocumentIDs: [document.id])
        XCTAssertEqual(
            try JSONDecoder().decode(WritingProject.self, from: JSONEncoder().encode(project)),
            project)
    }

    func testBothModesRoundTripOrderedDocumentsWithoutRewritingBodies() throws {
        let bodies = [
            "# 한글\r\n\r\n**강** \u{1100}\u{1161}\u{11BC}\r끝 👩🏽‍💻\n![그림](assets/a.png)\n$E=mc^2$\n",
            " \t\r\n\r ",
            ""
        ]
        let kinds: [WritingDocument.Kind] = [.reference, .manuscript, .note]
        for mode: WritingMode in [.general, .fiction] {
            let project = WritingProject(
                id: WritingProjectID(), title: "글 모음", mode: mode,
                documents: zip(bodies, kinds).enumerated().map { index, pair in
                    WritingDocument(
                        id: WritingDocumentID(), title: "문서 \(index)",
                        body: pair.0, kind: pair.1)
                })
            let decoded = try JSONDecoder().decode(
                WritingProject.self, from: JSONEncoder().encode(project))
            XCTAssertEqual(decoded.id, project.id)
            XCTAssertEqual(decoded.title, project.title)
            XCTAssertEqual(decoded.mode, mode)
            XCTAssertEqual(decoded.documents.map(\.id), project.documents.map(\.id))
            XCTAssertEqual(decoded.documents.map(\.title), project.documents.map(\.title))
            XCTAssertEqual(decoded.documents.map(\.kind), kinds)
            XCTAssertEqual(decoded.documents.count, bodies.count)
            for (document, body) in zip(decoded.documents, bodies) {
                XCTAssertEqual(document.body, body)
                XCTAssertEqual(Array(document.body.utf8), Array(body.utf8))
            }
        }
    }

    func testIdentitySurvivesBodyEditAndEncoding() throws {
        let projectUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let documentUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        var project = WritingProject(
            id: WritingProjectID(rawValue: projectUUID), title: "장편", mode: .fiction,
            documents: [WritingDocument(
                id: WritingDocumentID(rawValue: documentUUID), title: "초안",
                body: "처음", kind: .manuscript)])
        let editedBody = "수정\r\n\u{1100}\u{1161}\u{11BC} 👋"
        project.documents[0].body = editedBody
        let decoded = try JSONDecoder().decode(
            WritingProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.id.rawValue, projectUUID)
        XCTAssertEqual(decoded.documents[0].id.rawValue, documentUUID)
        XCTAssertEqual(decoded.documents[0].body, editedBody)
        XCTAssertEqual(Array(decoded.documents[0].body.utf8), Array(editedBody.utf8))
    }
}
