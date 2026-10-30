@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class WorkspacePresentationTests: XCTestCase {
    func testSnapshotValidatesToolsAndDockWithoutMutatingInputs() {
        for (raw, expected) in [("bible", SidebarSection.bible), ("timeline", .narrative), ("context", .context)] {
            let state = snapshot(section: raw, dock: "left")
            XCTAssertEqual(state.toolSection, expected); XCTAssertEqual(state.toolDock, .left)
            XCTAssertEqual(state.rawToolSection, raw); XCTAssertEqual(state.rawToolDock, "left")
            XCTAssertFalse(state.navigatorVisible); XCTAssertEqual(state.navigatorWidth, -10); XCTAssertTrue(state.chromeHidden)
        }
        for raw in ["files", "margin", "unknown"] {
            let state = snapshot(section: raw, dock: "invalid")
            XCTAssertNil(state.toolSection); XCTAssertEqual(state.toolDock, .automatic)
            XCTAssertEqual(state.rawToolSection, raw); XCTAssertEqual(state.rawToolDock, "invalid")
        }
    }
    func testStoryMapReservesTheExistingContextWithoutChangingSavedToolSelection() {
        let state = WorkspacePresentationState(navigatorVisible: true, navigatorWidth: 250,
            rawToolSection: "files", rawToolDock: "right", chromeHidden: false, mapVisible: true)
        XCTAssertTrue(state.contextVisible); XCTAssertEqual(state.rawToolSection, "files"); XCTAssertEqual(state.toolDock, .right)
    }
    private func snapshot(section: String, dock: String) -> WorkspacePresentationState {
        WorkspacePresentationState(navigatorVisible: false, navigatorWidth: -10,
            rawToolSection: section, rawToolDock: dock, chromeHidden: true)
    }
    @MainActor func testNativeSplittersSupportKeyboardAccessibilityWithoutReplacingEditor() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true)
        defer { h.close() }
        let editor = try await h.editor()
        let handle = try XCTUnwrap(h.element("purlory.tile.column-resize.0") as? SpatialResizeHandle)
        let before = try XCTUnwrap(h.requests.spatialWorkspace?.layout.columns.first?.width)
        XCTAssertTrue(handle.accessibilityPerformIncrement())
        await h.layout()
        XCTAssertGreaterThan(try XCTUnwrap(h.requests.spatialWorkspace?.layout.columns.first?.width), before)
        XCTAssertTrue(handle.accessibilityPerformDecrement())
        await h.layout()
        XCTAssertEqual(h.requests.spatialWorkspace?.layout.columns.first?.width, before)
        let retained = try await h.editor(); XCTAssertTrue(retained === editor)
    }
    func testPerDocumentStatisticsMatchSourceReadingRateAndGoalClamp() {
        let tiny = WorkspaceWritingStatistics(text: "한글🙂\nSecond", goal: 500)
        XCTAssertEqual(tiny.characters, 10)
        XCTAssertEqual(tiny.paragraphs, 2)
        XCTAssertEqual(tiny.readingSeconds, 10)
        XCTAssertEqual(tiny.progress, 0.02, accuracy: 0.0001)
        let full = WorkspaceWritingStatistics(text: String(repeating: "가", count: 900), goal: 500)
        XCTAssertEqual(full.readingSeconds, 120); XCTAssertEqual(full.progress, 1)
        XCTAssertEqual(WorkspaceWritingStatistics(text: "", goal: 0).progress, 0)
    }
}
