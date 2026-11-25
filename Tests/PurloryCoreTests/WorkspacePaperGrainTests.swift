@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class WorkspacePaperGrainTests: XCTestCase {
    func testPouchIndexViewDoesNotInstallPaperGrainOverlay() {
        let view = WorkspacePouchIndexView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        XCTAssertFalse(view.subviews.contains { String(describing: type(of: $0)).contains("Grain") })
    }
}
