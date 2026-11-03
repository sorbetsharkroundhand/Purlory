import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class EpubArchiveValidationTests: XCTestCase {
    func testManuscriptAndNoteArchivesPreserveContentWithWellFormedXML() async throws {
        let body = """
        # First chapter
        A & B < C
        [link](https://example.test/?q="word"&page=1)
        `**literal** $x$`
        ```swift
        let comparison = a < b
        ```
        앞 $x^2$ 뒤
        # Second chapter
        마지막 문장입니다.
        """
        for kind in [WritingDocument.Kind.manuscript, .note] {
            try await withExport(body: body, kind: kind) { archive in
                for member in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml",
                               "OEBPS/chapter0.xhtml", "OEBPS/chapter1.xhtml"] {
                    try assertValidXML(member, in: archive)
                }
                XCTAssertEqual(try epubMember("mimetype", in: archive), Data("application/epub+zip".utf8))
                let first = String(decoding: try epubMember("OEBPS/chapter0.xhtml", in: archive), as: UTF8.self)
                XCTAssertTrue(first.contains("A &amp; B &lt; C"))
                XCTAssertTrue(first.contains("<code>**literal** $x$</code>"))
                XCTAssertTrue(first.contains("<pre><code class=\"language-swift\">let comparison = a &lt; b"))
                XCTAssertTrue(first.contains("<msup>"))
                let last = String(decoding: try epubMember("OEBPS/chapter1.xhtml", in: archive), as: UTF8.self)
                XCTAssertTrue(last.contains("마지막 문장입니다."))
            }
        }
    }

    // In-progress Markdown is valid editor input; an open fence must not leave
    // the exported chapter's pre/code elements open and make the book unreadable.
    func testUnclosedCodeFenceStillProducesWellFormedXHTMLForBothDocumentKinds() async throws {
        for kind in [WritingDocument.Kind.manuscript, .note] {
            try await withExport(body: "Before\n```swift\nlet value = a < b && b > c", kind: kind) { archive in
                try assertValidXML("OEBPS/chapter0.xhtml", in: archive)
                let chapter = String(decoding: try epubMember("OEBPS/chapter0.xhtml", in: archive), as: UTF8.self)
                XCTAssertTrue(chapter.contains("let value = a &lt; b &amp;&amp; b &gt; c"))
            }
        }
    }

    private func withExport(
        body: String, kind: WritingDocument.Kind, inspect: (URL) throws -> Void
    ) async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()
        project.documents[0].title = "Export & compatibility"
        project.documents[0].body = body
        project.documents[0].kind = kind
        try await store.save(project)
        let catalog = try await store.assetCatalog(id: project.id)
        let archive = root.appendingPathComponent("book.epub")
        try await EpubExporter.exportAsync(project.documents[0], assets: catalog, to: archive)
        try inspect(archive)
    }

    private func assertValidXML(
        _ member: String, in archive: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let parser = XMLParser(data: try epubMember(member, in: archive))
        XCTAssertTrue(parser.parse(), "\(member): \(parser.parserError?.localizedDescription ?? "Invalid XML")",
                      file: file, line: line)
    }
}
