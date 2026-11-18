import AppKit
import XCTest
@testable import PurloryWorkspaceUI

@MainActor
final class EditorInputBenchmarkTests: XCTestCase {
    // Losing parent restoration would attribute the final storage edit to the nested commit.
    func testNestedOperationsRestoreParentAndNeverLeakAfterExit() {
        var time = 10.0
        let recorder = EditorInputTraceRecorder(clock: { defer { time += 1 }; return time })
        let parent = recorder.beginOperation(kind: .setMarkedText)
        let child = recorder.beginOperation(kind: .insertText)
        recorder.storageProcessed(range: NSRange(location: 0, length: 1), delta: 1, editedCharacters: true)
        recorder.endOperation(child)
        recorder.storageProcessed(range: NSRange(location: 1, length: 1), delta: 1, editedCharacters: true)
        recorder.endOperation(parent)
        recorder.storageProcessed(range: NSRange(location: 2, length: 0), delta: 0, editedCharacters: false)
        let rows = recorder.finish().samples.filter { $0.kind == "storage" }
        XCTAssertEqual(rows.count, 3)
        guard rows.count == 3 else { return }
        XCTAssertEqual(rows.map(\.operationID), [child.id, parent.id, nil])
        XCTAssertEqual(rows.map(\.revision), [1, 2, 2])
        XCTAssertEqual(recorder.finish().samples.first { $0.id == child.id }?.parentID, parent.id)
    }

    // Using end-of-draw revision incorrectly reports an edit made during drawing as observed.
    func testDrawCapturesStartRevisionAndCoalescesWithoutInventingObservations() {
        var times = Array(0...30).map(Double.init).makeIterator()
        let recorder = EditorInputTraceRecorder(clock: { times.next()! })
        for _ in 0..<2 {
            let operation = recorder.beginOperation(kind: .insertText)
            recorder.storageProcessed(range: NSRange(location: 0, length: 1), delta: 1, editedCharacters: true)
            recorder.endOperation(operation)
        }
        let draw = recorder.drawBegan(.zero)
        recorder.storageProcessed(range: NSRange(location: 0, length: 1), delta: 1, editedCharacters: true)
        recorder.drawEnded(draw)
        let report = InputBenchmarkMetrics(trace: recorder.finish())
        XCTAssertEqual(report.drawObservations.map(\.revision), [1, 2])
        XCTAssertEqual(Set(report.drawObservations.map(\.drawID)).count, 1)
        XCTAssertEqual(report.unmatchedRevisions, [3])
        XCTAssertEqual(recorder.finish().samples.last?.revision, 2)
    }

    // A recorder exceeding its bound must account for loss and freeze its returned snapshot.
    func testCapacityAndFinishAreBoundedAndImmutable() {
        let recorder = EditorInputTraceRecorder(capacity: 2, clock: { 1 })
        let token = recorder.beginOperation(kind: .insertText)
        recorder.storageProcessed(range: NSRange(location: 0, length: 1), delta: 1, editedCharacters: true)
        recorder.endOperation(token)
        let trace = recorder.finish()
        recorder.storageProcessed(range: NSRange(location: 1, length: 1), delta: 1, editedCharacters: true)
        XCTAssertEqual(trace.samples.count, 2)
        XCTAssertEqual(trace.droppedSamples, 1)
        XCTAssertEqual(recorder.finish().finalRevision, 1)
        XCTAssertEqual(recorder.finish().droppedSamples, 1)
    }

    // Invalid clock mapping must remain visible without erasing a finite native timestamp.
    func testEventTimestampsPreserveRawValuesAndRejectInvalidMapping() throws {
        let recorder = EditorInputTraceRecorder(clock: { 10 })
        for timestamp in [9.0, 11.0, -1.0, .infinity] {
            let token = recorder.beginOperation(kind: .keyDown, eventTimestamp: timestamp)
            recorder.endOperation(token)
        }
        let data = try JSONEncoder().encode(recorder.finish())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(object["samples"] as? [[String: Any]]).filter { $0["kind"] as? String == "operation.begin.keyDown" }
        XCTAssertEqual(rows.compactMap { $0["eventTimestamp"] as? Double }, [9, 11, -1])
        XCTAssertEqual(rows.compactMap { $0["eventTimestampComparable"] as? Bool }, [true, false, false, false])
    }

    // Duplicate matrix values would silently produce indistinguishable repeated run IDs.
    func testConfigurationRejectsDuplicateMatrixCells() {
        for (key, value) in [("SIZES", "1000,1000"), ("SHAPES", "short,short"),
                             ("FORMATS", "plain,plain"), ("POSITIONS", "middle,middle"),
                             ("TRACES", "latin,latin"), ("TIMINGS", "idle,idle")] {
            XCTAssertThrowsError(try InputBenchmarkConfiguration(environment: ["PURLORY_INPUT_BENCHMARK_" + key: value]), key)
        }
        for value in ["nan", "inf", "0", "1001"] {
            XCTAssertThrowsError(try InputBenchmarkConfiguration(environment: ["PURLORY_INPUT_BENCHMARK_CADENCE_MS": value]))
        }
    }

    func testLocalDocumentIntegrityDistinguishesComposedAndDecomposedHangul() {
        XCTAssertTrue(inputBenchmarkTextMatches("한", "한"))
        XCTAssertFalse(inputBenchmarkTextMatches("한", "\u{1112}\u{1161}\u{11AB}"))
    }

    func testLocalDocumentPreservesWholeUTF8File() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture-with-private-name.md")
        let fixture = "# First\n\n아🎈\r\nlast\n"
        try Data(fixture.utf8).write(to: url)
        let loaded = try InputBenchmarkFixture.loadLocalDocument(from: url)
        XCTAssertEqual(loaded.text, fixture)
        XCTAssertEqual(loaded.metadata.characterCount, 17)
        XCTAssertEqual(loaded.metadata.utf16Count, 19)
        XCTAssertEqual(loaded.metadata.utf8Count, 23)
        XCTAssertEqual(loaded.metadata.paragraphCount, 5)
        XCTAssertEqual(loaded.metadata.format, .markdown)
        XCTAssertEqual(loaded.metadata.origin, .localDocument)
        XCTAssertNil(loaded.metadata.shape)
        XCTAssertEqual(midpointAtCharacterBoundary(in: "aa🎈z" as NSString), 2)
        XCTAssertEqual(midpointAtCharacterBoundary(in: "aa🎈zzz" as NSString), 2)
        try Data([0xFF]).write(to: url)
        XCTAssertThrowsError(try InputBenchmarkFixture.loadLocalDocument(from: url)) { error in
            XCTAssertFalse(String(describing: error).contains(url.lastPathComponent))
        }
    }

    func testLocalDocumentConfigurationExcludesGeneratedFixtures() throws {
        let environment = ["PURLORY_INPUT_BENCHMARK_LOCAL_DOCUMENT": "/unused/private-fixture.md"]
        let configuration = try InputBenchmarkConfiguration(environment: environment)
        XCTAssertEqual(configuration.fixtureOrigin, .localDocument)
        XCTAssertTrue(configuration.sizes.isEmpty)
        XCTAssertTrue(configuration.shapes.isEmpty)
        XCTAssertTrue(configuration.formats.isEmpty)
        let conflict = environment.merging(["PURLORY_INPUT_BENCHMARK_SIZES": "1000"]) { _, value in value }
        XCTAssertThrowsError(try InputBenchmarkConfiguration(environment: conflict))
        let json = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        XCTAssertFalse(json.contains("private-fixture.md"))
    }

    func testConfigurationAcceptsMovingAndFixedPositionsTogether() throws {
        let configuration = try InputBenchmarkConfiguration(environment: [
            "PURLORY_INPUT_BENCHMARK_POSITIONS": "start,middle,end,moving"
        ])
        XCTAssertEqual(configuration.positions, ["start", "middle", "end", "moving"])
        XCTAssertEqual(try InputBenchmarkConfiguration(environment: [:]).positions, configuration.positions)
    }

    func testNearestRankPreservesTailAndMissingMeasurements() {
        let stats = InputBenchmarkDistribution([1, 2, 3, 4, 100])
        XCTAssertEqual(stats?.p50, 3)
        XCTAssertEqual(stats?.p95, 100)
        XCTAssertEqual(stats?.p99, 100)
        XCTAssertEqual(stats?.max, 100)
        XCTAssertEqual(stats?.n, 5)
        XCTAssertNil(InputBenchmarkDistribution([]))
    }

    func testFixturesHaveExactBMPSizeAndDistinctShapeAndFormat() {
        for size in [1_000, 10_000, 100_000, 230_544, 500_000, 1_000_000] {
            for shape in InputBenchmarkFixture.Shape.allCases {
                for format in InputBenchmarkFixture.Format.allCases {
                    let fixture = InputBenchmarkFixture(size: size, shape: shape, format: format)
                    XCTAssertEqual(fixture.text.count, size)
                    XCTAssertEqual(fixture.text.utf16.count, size)
                    XCTAssertEqual(fixture.metadata.utf16Count, size)
                    XCTAssertEqual(fixture.metadata.paragraphCount > 1, shape == .short)
                    XCTAssertEqual(fixture.text.contains("**"), format == .markdown)
                    XCTAssertEqual(fixture.metadata.sha256.count, 64)
                }
            }
        }
    }
    // Missing hooks would hide storage/coordinator work; attaching them must preserve accepted text.
    func testWorkspaceHooksPreserveEditingAndDefaultToDisabled() async throws {
        let harness = try await FramedWorkspaceHarness()
        defer { harness.close() }
        harness.fixture.session.updateSelectedDocumentBody("original")
        let editor = try await harness.editor()
        XCTAssertNil(editor.inputTraceRecorder)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertText("A", replacementRange: editor.selectedRange())
        undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "originalA")
        editor.breakUndoCoalescing()
        undo.removeAllActions()
        let recorder = EditorInputTraceRecorder()
        editor.inputTraceRecorder = recorder
        undo.beginUndoGrouping()
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.markedRange())
        editor.insertText("한", replacementRange: editor.markedRange())
        undo.endUndoGrouping()
        editor.inputTraceRecorder = nil
        XCTAssertEqual(editor.string, "originalA한")
        let trace = recorder.finish()
        XCTAssertTrue(trace.samples.contains { $0.kind == "operation.begin.setMarkedText" })
        XCTAssertTrue(trace.samples.contains { $0.kind == "operation.begin.insertText" })
        XCTAssertTrue(trace.samples.contains { $0.kind == "storage" && $0.editedCharacters == true })
        for phase in ["serialization", "binding", "projection", "forwarding", "coordinator"] {
            XCTAssertTrue(trace.samples.contains { $0.kind == "phase.begin." + phase }, phase)
        }
        XCTAssertTrue(trace.samples.allSatisfy { $0.eventTimestamp == nil })
        undo.undo()
        XCTAssertEqual(editor.string, "originalA")
        undo.redo()
        XCTAssertEqual(editor.string, "originalA한")
    }

    func testMovingReferenceModelUsesCurrentDocumentLocations() {
        let fixture = "0123456789012345678901234567890123456789"
        let latin = String(repeating: "a", count: 12)
        XCTAssertEqual(InputBenchmarkTrace.latin.expectedText(fixture, location: 0, moving: true),
            latin + latin + "01234567890123" + latin + "45678901234567890123456789" + latin)
        XCTAssertEqual(InputBenchmarkTrace.hangul.expectedText(fixture, location: 0, moving: true),
            "한한한한한한한한012345678901234567한한한한8901234567890123456789한한한한")
    }

    func testTraceReferenceModelHasIndependentExpectedContent() {
        XCTAssertEqual(InputBenchmarkTrace.latin.expectedText("abcd", location: 2), "abaaaaaaaaaaaacd")
        XCTAssertEqual(InputBenchmarkTrace.hangul.expectedText("abcd", location: 2), "ab한한한한cd")
        XCTAssertEqual(InputBenchmarkTrace.editing.expectedText("abcd", location: 2), "abZZcd")
        XCTAssertEqual(InputBenchmarkTrace.paste.expectedText("abcd", location: 2), "ab" + String(repeating: "Synthetic paste. ", count: 8) + "cd")
    }

}
