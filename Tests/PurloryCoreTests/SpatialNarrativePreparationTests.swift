@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class SpatialNarrativePreparationTests: XCTestCase {
    func testNarrativeTilePreparesVerifiedRowsWhileWritingModeRemainsWrite() async throws {
        let f = try await LegacyBoundaryFixture(mode: .fiction); defer { f.cleanUp() }
        f.session.updateSelectedDocumentBody("# First scene\nOriginal scene.\n# Second scene\nAnother original.")
        let controller = StoryMapController(session: f.session, requiresMapMode: false, observeEnergy: false, sleep: {})
        controller.update(); await controller.waitForCurrentWork()
        XCTAssertEqual(f.session.workspaceMode, .write)
        XCTAssertEqual(controller.prepared?.projection.scenes.count, 2)
        XCTAssertTrue(controller.prepared?.projection.rows.allSatisfy { row in
            f.session.selectedDocument?.body.contains(row.evidence.quote) == true
        } == true)
        controller.stop()
    }
}
