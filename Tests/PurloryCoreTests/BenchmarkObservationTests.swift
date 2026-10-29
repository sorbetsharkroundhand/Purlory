@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore

final class BenchmarkObservationTests: XCTestCase {
    func testRawChunksSurviveSentenceCutWithoutChangingDisplayedText() {
        var observation = CompletionEngine.TextObservation()
        let chunk = "바람이 불었다. 漢字 <think>분석</think>Assistant:"
        XCTAssertTrue(observation.append(chunk, stopAtUtteranceEnd: false))
        XCTAssertEqual(observation.displayed(style: .continuation), "바람이 불었다.")
        XCTAssertEqual(observation.rawText, chunk)
        XCTAssertEqual(BenchmarkContamination.count(observation.rawText).hanCharacters, 2)
    }
    func testThinkingSanitizationDoesNotEraseRawEvidence() {
        var observation = CompletionEngine.TextObservation()
        let chunk = "<think>漢字</think> 봄바람"
        XCTAssertFalse(observation.append(chunk, stopAtUtteranceEnd: false))
        XCTAssertEqual(observation.displayed(style: .continuation), "봄바람")
        XCTAssertEqual(observation.rawText, chunk)
        XCTAssertEqual(BenchmarkContamination.count(observation.rawText).reasoningTags, 2)
    }
    func testReportPreflightRejectsBadOptionsAndExistingOutputBeforeLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-BenchPreflight-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.txt"), output = root.appendingPathComponent("report.json")
        try Data("한글 원고".utf8).write(to: fixture)
        let model = ModelPresets.qwen2_5_1_5B
        XCTAssertThrowsError(try ReleaseBenchmarkPreflight.validate(modelID: "unregistered/model", fixture: fixture, output: output, candidateBudget: nil, temperature: 0))
        XCTAssertThrowsError(try ReleaseBenchmarkPreflight.validate(modelID: model, fixture: nil, output: output, candidateBudget: nil, temperature: 0))
        XCTAssertThrowsError(try ReleaseBenchmarkPreflight.validate(modelID: model, fixture: fixture, output: output, candidateBudget: 0, temperature: 0))
        XCTAssertThrowsError(try ReleaseBenchmarkPreflight.validate(modelID: model, fixture: fixture, output: output, candidateBudget: nil, temperature: .infinity))
        XCTAssertThrowsError(try ReleaseBenchmarkPreflight.validate(modelID: model, fixture: root.appendingPathComponent("missing.txt"), output: output, candidateBudget: nil, temperature: 0))
        try Data("preserve".utf8).write(to: output)
        XCTAssertThrowsError(try ReleaseBenchmarkPreflight.validate(modelID: model, fixture: fixture, output: output, candidateBudget: nil, temperature: 0))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "preserve")
    }
    func testValidPreflightCreatesNoOutputOrInstallationData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-BenchPreflight-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.txt"), output = root.appendingPathComponent("report.json")
        try Data("한글 원고".utf8).write(to: fixture)
        XCTAssertNoThrow(try ReleaseBenchmarkPreflight.validate(modelID: ModelPresets.qwen2_5_1_5B, fixture: fixture, output: output, candidateBudget: 2 << 30, temperature: 0))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fixture.txt"])
    }
}
