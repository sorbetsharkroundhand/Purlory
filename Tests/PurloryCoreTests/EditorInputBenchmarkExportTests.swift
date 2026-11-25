import AppKit
import XCTest
@testable import PurloryWorkspaceUI

@MainActor
extension EditorInputBenchmarkTests {
    func testMovingScheduleExportsCaretScrollAndFirstInput() throws {
        let configuration = try InputBenchmarkConfiguration(environment: ["PURLORY_INPUT_BENCHMARK_POSITIONS": "moving"])
        let fixture = InputBenchmarkFixture(size: 1000, shape: .short, format: .plain)
        let movement = InputBenchmarkRun.DispatchSample(sequence: 12, action: .moveToMiddle, requested: 1, started: 1, ended: 2,
            segmentID: 1, selectionBeforeUTF16: 12, firstInputAfterMove: nil, caretMove: .init(
                requestedUTF16Location: 506, selectedUTF16Location: 506, scrollOriginYBefore: 5, scrollOriginYAfter: 40, operationID: 22))
        let first = InputBenchmarkRun.DispatchSample(sequence: 13, action: .latin, requested: 2, started: 3, ended: 4,
            segmentID: 1, selectionBeforeUTF16: 506, firstInputAfterMove: true, caretMove: nil)
        let run = InputBenchmarkRun(scenarioID: "1000-short-plain-moving-latin-immediate", runID: 2,
            burstID: 0, target: "native", fixture: fixture.metadata, position: "moving", activeParagraphUTF16Count: 50,
            initialRenderedUTF16Count: 1000, traceKind: .latin, timing: "immediate", elapsedIdleSeconds: 0, started: 1, ended: 4,
            settings: [:], referenceSettings: [:], settingsDifferences: [], scope: [:], visibilityBefore: [:], visibilityAfter: [:],
            countersBefore: [:], countersAfter: [:], integrity: [:], schedule: [movement, first], probes: [], trace: nil, metrics: nil,
            dispatchDurationSeconds: nil, syntheticSchedulingDelaySeconds: nil, caretMoveDurationSeconds: nil,
            firstPostMoveDispatchDurationSeconds: nil, firstPostMoveSchedulingDelaySeconds: nil, probeDelaySeconds: nil)
        let report = InputBenchmarkReport(schemaVersion: 3, clock: "ProcessInfo.systemUptime", timestampUnit: "seconds",
            configuration: configuration, provenance: [:], environment: [:], limitations: [], runs: [run])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("input-moving-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try report.write(to: directory)
        let decoded = try JSONDecoder().decode(InputBenchmarkReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("report.json")))
        let decodedRows = try XCTUnwrap(decoded.runs.first?.schedule)
        XCTAssertEqual(decodedRows.first?.caretMove?.requestedUTF16Location, 506)
        XCTAssertEqual(decodedRows.first?.caretMove?.scrollOriginYAfter, 40)
        XCTAssertEqual(decodedRows.first?.caretMove?.operationID, 22)
        XCTAssertEqual(decodedRows.last?.firstInputAfterMove, true)
        let csv = try String(contentsOf: directory.appendingPathComponent("schedule.csv"), encoding: .utf8)
        let rows = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.count == rows[0].count })
        let moveRow = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))
        let inputRow = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[2]))
        XCTAssertEqual(moveRow["action"], "moveToMiddle")
        XCTAssertEqual(moveRow["selection_before_utf16"], "12")
        XCTAssertEqual(moveRow["move_requested_utf16"], "506")
        XCTAssertEqual(moveRow["move_selected_utf16"], "506")
        XCTAssertEqual(moveRow["scroll_origin_y_before"], "5.0")
        XCTAssertEqual(moveRow["scroll_origin_y_after"], "40.0")
        XCTAssertEqual(moveRow["move_operation_id"], "22")
        XCTAssertEqual(moveRow["segment_id"], inputRow["segment_id"])
        XCTAssertEqual(inputRow["selection_before_utf16"], "506")
        XCTAssertEqual(inputRow["first_input_after_move"], "true")
        XCTAssertEqual(inputRow["move_requested_utf16"], "")
    }

    // Dropping IDs, inventing empty metrics, leaking fixture text or overwriting reports breaks export consumers.
    func testExportsPreserveRawCorrelationAndMissingMetricsWithoutOverwriting() throws {
        var time = 10.0
        let recorder = EditorInputTraceRecorder(clock: { defer { time += 1 }; return time })
        let token = recorder.beginOperation(kind: .insertText)
        recorder.storageProcessed(range: NSRange(location: 0, length: 1), delta: 1, editedCharacters: true)
        recorder.endOperation(token)
        let captured = recorder.finish()
        let fixture = InputBenchmarkFixture(size: 1000, shape: .short, format: .plain)
        let configuration = try InputBenchmarkConfiguration(environment: [:])
        let run = InputBenchmarkRun(scenarioID: "1000-short-plain-middle-latin-immediate", runID: 2,
            burstID: 0, target: "native", fixture: fixture.metadata, position: "middle",
            activeParagraphUTF16Count: 50, initialRenderedUTF16Count: 1000, traceKind: .latin,
            timing: "immediate", elapsedIdleSeconds: 0, started: 10, ended: 12,
            settings: [:], referenceSettings: [:], settingsDifferences: [], scope: [:],
            visibilityBefore: [:], visibilityAfter: [:], countersBefore: [:], countersAfter: [:],
            integrity: ["finalText": "passed"], schedule: [], probes: [], trace: captured,
            metrics: InputBenchmarkMetrics(trace: captured), dispatchDurationSeconds: nil,
            syntheticSchedulingDelaySeconds: nil, caretMoveDurationSeconds: nil, firstPostMoveDispatchDurationSeconds: nil,
            firstPostMoveSchedulingDelaySeconds: nil, probeDelaySeconds: nil)
        let report = InputBenchmarkReport(schemaVersion: 3, clock: "ProcessInfo.systemUptime",
            timestampUnit: "seconds", configuration: configuration, provenance: [:], environment: [:],
            limitations: [], runs: [run])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("input-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try report.write(to: directory)
        let jsonURL = directory.appendingPathComponent("report.json")
        let original = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(InputBenchmarkReport.self, from: original)
        XCTAssertEqual(decoded.runs.first?.trace?.samples.map(\.timestamp), [10, 11, 12])
        XCTAssertEqual(decoded.runs.first?.trace?.samples.map(\.operationID), [1, 1, 1])
        XCTAssertEqual(decoded.runs.first?.metrics?.unmatchedRevisions, [1])
        XCTAssertNil(decoded.runs.first?.metrics?.distributionsSeconds["storageToObservedDrawEnd"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let exportedRun = try XCTUnwrap((object["runs"] as? [[String: Any]])?.first)
        XCTAssertNil(exportedRun["probeDelaySeconds"])
        XCTAssertNil(exportedRun["dispatchDurationSeconds"])
        XCTAssertFalse(String(decoding: original, as: UTF8.self).contains("마을"))
        let csv = try String(contentsOf: directory.appendingPathComponent("trace.csv"), encoding: .utf8)
        let lines = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(lines.count, 4)
        let header = lines[0]
        let storage = Dictionary(uniqueKeysWithValues: zip(header, lines[2]))
        XCTAssertEqual(storage["timestamp_seconds"], "11.0")
        XCTAssertEqual(storage["operation_id"], "1")
        XCTAssertEqual(storage["revision"], "1")
        XCTAssertEqual(storage["event_timestamp_seconds"], "")
        XCTAssertEqual(storage["event_timestamp_comparable"], "")
        XCTAssertTrue(lines.allSatisfy { $0.count == header.count })
        XCTAssertFalse(csv.contains("마을"))
        XCTAssertThrowsError(try report.write(to: directory))
        XCTAssertEqual(try Data(contentsOf: jsonURL), original)
        for name in ["schedule.csv", "probes.csv"] {
            let rows = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(rows.count, 1, name)
        }
    }
}
