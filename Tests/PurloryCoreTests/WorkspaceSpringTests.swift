import AppKit
import XCTest
@testable import PurloryWorkspaceUI

final class WorkspaceSpringTests: XCTestCase {
    func testCriticalSpringSettlesWithoutOvershootingFromRest() {
        var spring = WorkspaceSpringValue(value: 0)
        var previous: CGFloat = 0
        for _ in 0..<48 {
            spring.advance(to: 1000, elapsed: 1 / 60)
            XCTAssertGreaterThanOrEqual(spring.value, previous)
            XCTAssertLessThanOrEqual(spring.value, 1000)
            previous = spring.value
        }
        XCTAssertTrue(spring.isSettled(at: 1000))
    }

    func testRetargetKeepsPositionAndVelocityBeforeReversing() {
        var spring = WorkspaceSpringValue(value: 0)
        spring.advance(to: 1000, elapsed: 0.08)
        let value = spring.value, velocity = spring.velocity
        spring.advance(to: -1000, elapsed: 0)
        XCTAssertEqual(spring.value, value); XCTAssertEqual(spring.velocity, velocity)
        spring.advance(to: -1000, elapsed: 0.001)
        XCTAssertGreaterThan(spring.value, value)
        spring.advance(to: -1000, elapsed: 0.8)
        XCTAssertTrue(spring.isSettled(at: -1000))
    }

    func testDisplayCadenceAndDelayedFramesHaveEquivalentStates() {
        let start = CGRect(x: 20, y: 30, width: 1000, height: 700)
        let target = CGRect(x: 200, y: 100, width: 400, height: 300)
        var sixty = WorkspaceSpringRect(frame: start)
        var promotion = WorkspaceSpringRect(frame: start)
        var delayed = WorkspaceSpringRect(frame: start)
        for _ in 0..<6 { sixty.advance(to: target, elapsed: 1 / 60) }
        for _ in 0..<12 { promotion.advance(to: target, elapsed: 1 / 120) }
        delayed.advance(to: target, elapsed: 0.1)
        for frame in [promotion.frame, delayed.frame] {
            XCTAssertEqual(frame.minX, sixty.frame.minX, accuracy: 0.000001)
            XCTAssertEqual(frame.minY, sixty.frame.minY, accuracy: 0.000001)
            XCTAssertEqual(frame.width, sixty.frame.width, accuracy: 0.000001)
            XCTAssertEqual(frame.height, sixty.frame.height, accuracy: 0.000001)
        }
        delayed.advance(to: target, elapsed: 1)
        XCTAssertTrue(delayed.isSettled(at: target))
    }
}
