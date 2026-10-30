@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class ShortcutHintPresentationTests: XCTestCase {
    func testWorkspaceDoesNotExposeTheRetiredShortcutCapsule() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        XCTAssertNil(h.element("purlory.ghost-shortcut-hint"))
        XCTAssertEqual(h.requests.nativeEditor?.selectedRange().length, 0)
    }
}
