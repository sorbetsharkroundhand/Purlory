@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class WorkspaceOriginalParagraphTests: XCTestCase {
    func testReadOnlyMappingKeepsCodeFencesWithTheirOwnBlock() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let original = "```\nx\n```\nAfter"
        h.fixture.session.updateSelectedDocumentBody(original)
        let editor = try await h.editor(), native = editor.string as NSString
        let code = native.paragraphRange(for: native.range(of: "x"))
        let after = native.paragraphRange(for: native.range(of: "After"))
        let selection = editor.selectedRange()
        let codeSource = try XCTUnwrap(editor.originalParagraphRange(forNative: code))
        let afterSource = try XCTUnwrap(editor.originalParagraphRange(forNative: after))
        XCTAssertEqual((original as NSString).substring(with: codeSource), "```\nx\n```\n")
        XCTAssertEqual((original as NSString).substring(with: afterSource), "After")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.serialize(), original)
    }
}
