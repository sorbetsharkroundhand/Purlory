@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class WorkspaceRoutingTests: XCTestCase {
    func testFictionRoutesWriteMapReview() {
        XCTAssertEqual(
            WorkspaceRouting.availableModes(for: .fiction),
            [.write, .map, .review])
    }

    func testGeneralRoutesWriteOutlineReview() {
        XCTAssertEqual(
            WorkspaceRouting.availableModes(for: .general),
            [.write, .outline, .review])
    }

    func testUnsupportedSavedModeFallsBackToWrite() {
        XCTAssertEqual(
            WorkspaceRouting.normalizedSelection(.map, for: .general),
            .write)
        XCTAssertEqual(
            WorkspaceRouting.normalizedSelection(.outline, for: .fiction),
            .write)
        XCTAssertEqual(
            WorkspaceRouting.normalizedSelection(.review, for: .general),
            .review)
    }
}
