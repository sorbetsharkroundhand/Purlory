@testable import PurloryWorkspaceUI
import XCTest

final class KeystrokeMeasurementTests: XCTestCase {
    @MainActor
    func testRollingStatisticsPublishEveryTwentyAcceptedSamples() throws {
        let suite = "Purlory.KeystrokeMeasurementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let settings = CompletionSettings(defaults: defaults)
        XCTAssertFalse(settings.autocompleteEnabled)
        let controller = CompletionController(settings: settings)
        let unpublished = controller.keystrokeStats

        for _ in 0..<19 {
            controller.noteKeystroke(handlerMs: 1, totalMs: 2)
            XCTAssertEqual(controller.keystrokeStats, unpublished)
        }
        controller.noteKeystroke(handlerMs: 1, totalMs: 2)
        XCTAssertEqual(controller.keystrokeStats.samples, 20)
        XCTAssertEqual(controller.keystrokeStats.handlerP95, 1)
        XCTAssertEqual(controller.keystrokeStats.totalP95, 2)
        XCTAssertEqual(controller.keystrokeStats.totalMax, 2)

        for _ in 20..<120 {
            controller.noteKeystroke(handlerMs: 1, totalMs: 2)
        }
        let publishedAt120 = controller.keystrokeStats
        XCTAssertEqual(publishedAt120.samples, 120)

        for _ in 0..<19 {
            controller.noteKeystroke(handlerMs: 50, totalMs: 100)
            XCTAssertEqual(controller.keystrokeStats, publishedAt120)
        }
        controller.noteKeystroke(handlerMs: 50, totalMs: 100)
        XCTAssertEqual(controller.keystrokeStats.samples, 120)
        XCTAssertEqual(controller.keystrokeStats.handlerP95, 50)
        XCTAssertEqual(controller.keystrokeStats.totalP95, 100)
        XCTAssertEqual(controller.keystrokeStats.totalMax, 100)

        let publishedAt140 = controller.keystrokeStats
        for _ in 0..<19 {
            controller.noteKeystroke(handlerMs: 200, totalMs: 400)
            XCTAssertEqual(controller.keystrokeStats, publishedAt140)
        }
        controller.noteKeystroke(handlerMs: 200, totalMs: 400)
        XCTAssertEqual(controller.keystrokeStats.samples, 120)
        XCTAssertEqual(controller.keystrokeStats.handlerP95, 200)
        XCTAssertEqual(controller.keystrokeStats.totalP95, 400)
        XCTAssertEqual(controller.keystrokeStats.totalMax, 400)
    }
}
