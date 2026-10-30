@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class WindowChromeGeometryTests: XCTestCase {
    @MainActor
    func testMeasurementProbeDoesNotInterceptWindowDragging() {
        let probe = WindowChromeProbe.ProbeView(frame: NSRect(x: 0, y: 0, width: 1180, height: 52))
        XCTAssertNil(probe.hitTest(NSPoint(x: 30, y: 20)))
    }

    func testMissingWindowGeometryUsesDesignPadding() {
        XCTAssertEqual(
            WindowChromeGeometry.leadingContentInset(trafficLightMaxX: nil),
            WindowChromeGeometry.navigatorBaseLeadingPadding)
        XCTAssertEqual(
            WindowChromeGeometry.leadingContentInset(trafficLightMaxX: 0),
            WindowChromeGeometry.navigatorBaseLeadingPadding)
    }

    func testMeasuredTrafficLightsDefineLeadingSafeRegion() {
        XCTAssertEqual(
            WindowChromeGeometry.leadingContentInset(trafficLightMaxX: 68),
            80)
    }

    func testTinyMeasuredValueNeverShrinksDesignPadding() {
        XCTAssertEqual(
            WindowChromeGeometry.leadingContentInset(trafficLightMaxX: 2),
            WindowChromeGeometry.navigatorBaseLeadingPadding)
    }
}
