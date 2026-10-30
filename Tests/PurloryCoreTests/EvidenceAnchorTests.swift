@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class EvidenceAnchorTests: XCTestCase {
    private let documentID = WritingDocumentID()

    func testResolvesExactQuote() {
        let anchor = EvidenceAnchor(
            documentID: documentID,
            sceneHash: "scene-a",
            quote: "The brass key was warm.",
            utf16Hint: 8)

        XCTAssertEqual(
            anchor.resolvedQuery(in: "Before. The brass key was warm. After."),
            "The brass key was warm.")
    }

    func testDelegatesResilientLookupAfterSmallEdit() {
        let anchor = EvidenceAnchor(
            documentID: documentID,
            quote: "The brass key was warm in her palm.")

        XCTAssertEqual(
            anchor.resolvedQuery(in: "The brass key was warm against her palm."),
            "The brass ke")
    }

    func testUTF16HintDoesNotMakeStaleEvidenceJumpable() {
        let anchor = EvidenceAnchor(
            documentID: documentID,
            quote: "The missing sentence.",
            utf16Hint: 0)

        XCTAssertNil(anchor.resolvedQuery(in: "An unrelated replacement paragraph."))
    }

    func testCodableRoundTripPreservesIdentityAndHints() throws {
        let anchor = EvidenceAnchor(
            documentID: documentID,
            sceneHash: "scene-a",
            quote: "Evidence",
            utf16Hint: 17)

        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(EvidenceAnchor.self, from: data)

        XCTAssertEqual(decoded, anchor)
    }
}
