@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore

final class ReleaseBenchmarkReportTests: XCTestCase {
    func testContextStrategyMetadataRoundTripAndLegacyAbsence() throws {
        var current = metadata
        current.ghostContextMode = .rawWithNameAnchor
        current.originalAnchorNames = ["유정", "서연"]
        current.originalAnchorOpportunities = 42
        let encoded = try JSONEncoder().encode(current)
        let decoded = try JSONDecoder().decode(ReleaseBenchmarkReport.Metadata.self, from: encoded)
        XCTAssertEqual(decoded.ghostContextMode, .rawWithNameAnchor)
        XCTAssertEqual(decoded.originalAnchorNames, ["유정", "서연"])
        XCTAssertEqual(decoded.originalAnchorOpportunities, 42)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["ghostContextMode", "originalAnchorNames", "originalAnchorOpportunities"] { old.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(ReleaseBenchmarkReport.Metadata.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.ghostContextMode)
        XCTAssertNil(legacy.originalAnchorNames)
        XCTAssertNil(legacy.originalAnchorOpportunities)
    }

    private var metadata: ReleaseBenchmarkReport.Metadata {
        .init(modelID: "fixture/model", revision: String(repeating: "a", count: 40), fixtureSHA256: String(repeating: "b", count: 64),
              physicalMemoryBytes: 16 << 30, recommendedWorkingSetBytes: 12 << 30, device: "Fixture Mac", os: "Fixture OS", toolchain: "Fixture Swift",
              style: .continuation, maxTokens: 12, temperature: 0, contextCharacters: 200, declaredPeakBudgetBytes: 2 << 30)
    }
    private func sample(cold: String = "바람이 불었다", raw: String = "<think>漢字</think>Assistant: 바람이 불었다", coldTTFC: Double? = 1,
                        warmTTFC: Double? = 0.1, prompt: Int = 100, reused: Int = 90,
                        coldTTFT: Double? = nil, warmTTFT: Double? = nil) -> ReleaseBenchmarkSample {
        .init(coldText: cold, warmText: "바람이 불었다", rawColdText: raw, rawWarmText: "바람이 불었다", truth: "바람이 불었다.",
              coldTTFC: coldTTFC, warmTTFC: warmTTFC, warmPromptTokens: prompt, warmReusedTokens: reused,
              coldTTFT: coldTTFT, warmTTFT: warmTTFT)
    }
    func testKnownContaminationFixturesAndCleanKorean() {
        let fixtures: [(String, Int, Int, Int)] = [
            ("그는 문을 열고 조용히 걸었다.", 0, 0, 0),
            ("漢字", 2, 0, 0), ("\u{20000}", 1, 0, 0),
            ("<think>생각</think><analysis>분석</analysis>", 0, 4, 0),
            ("Assistant: 답변: <|im_start|>assistant ### assistant", 0, 0, 4),
            ("analysis of an assistant in fiction", 0, 0, 0)
        ]
        for (text, han, reasoning, chat) in fixtures {
            let count = BenchmarkContamination.count(text)
            XCTAssertEqual(count.hanCharacters, han, text); XCTAssertEqual(count.reasoningTags, reasoning, text)
            XCTAssertEqual(count.chatBoilerplate, chat, text)
        }
    }
    func testJointMetricsKeepRawContaminationAndWeightedKVReuse() throws {
        let report = try ReleaseBenchmarkReport(metadata: metadata,
            samples: [sample(), sample(cold: "다른 이야기", raw: "깨끗한 글", coldTTFC: 3, warmTTFC: 0.3, prompt: 300, reused: 150)],
            attempted: 2, mlxPeakBytes: 123, processPeakBytes: 456)
        XCTAssertEqual(report.coldTTFCMean, 2); XCTAssertEqual(try XCTUnwrap(report.warmTTFCMean), 0.2, accuracy: 0.0001)
        XCTAssertEqual(report.eojeolHitRate, 0.5); XCTAssertEqual(report.prefixHitRate, 0.5)
        XCTAssertEqual(report.kvReuseRate, 0.6)
        XCTAssertEqual(report.rawContamination.hanCharacters, 2)
        XCTAssertEqual(report.rawContamination.reasoningTags, 2)
        XCTAssertEqual(report.rawContamination.chatBoilerplate, 1)
        XCTAssertEqual(report.displayedContamination.hanCharacters, 0)
        XCTAssertEqual(report.failedSamples, 0)
    }
    func testMissingSamplesUseNullAndExposeIncompleteRun() throws {
        let report = try ReleaseBenchmarkReport(metadata: metadata, samples: [], attempted: 3, mlxPeakBytes: nil, processPeakBytes: nil)
        XCTAssertEqual(report.failedSamples, 3); XCTAssertNil(report.coldTTFCMean); XCTAssertNil(report.kvReuseRate)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        for key in ["coldTTFCMean", "warmTTFCMean", "kvReuseRate", "eojeolHitRate", "mlxPeakBytes", "processPeakBytes"] {
            XCTAssertTrue(json[key] is NSNull, key)
        }
    }
    func testMissingChunksAreExcludedFromLatencyMeanWithoutZeroBias() throws {
        let report = try ReleaseBenchmarkReport(metadata: metadata, samples: [sample(coldTTFC: nil, warmTTFC: nil, prompt: 0, reused: 0), sample()],
                                                attempted: 2, mlxPeakBytes: 1, processPeakBytes: 2)
        XCTAssertEqual(report.coldTTFCMean, 1); XCTAssertEqual(report.coldLatencySamples, 1)
        XCTAssertEqual(report.warmTTFCMean, 0.1); XCTAssertEqual(report.warmLatencySamples, 1)
        XCTAssertEqual(report.kvReuseRate, 0.9)
    }
    func testChunkLatencyDoesNotStandInForMissingFirstTokenMeasurement() throws {
        let report = try ReleaseBenchmarkReport(metadata: metadata, samples: [sample()], attempted: 1,
                                                mlxPeakBytes: nil, processPeakBytes: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertTrue(json["coldTTFTMean"] is NSNull)
        XCTAssertTrue(json["warmTTFTMean"] is NSNull)
        XCTAssertEqual(json["coldFirstTokenSamples"] as? Int, 0)
        XCTAssertEqual(json["warmFirstTokenSamples"] as? Int, 0)
        XCTAssertEqual(json["coldTTFCMean"] as? Double, 1)
    }
    func testFirstTokenMeansUseIndependentSampleCountsAndRoundTrip() throws {
        let report = try ReleaseBenchmarkReport(metadata: metadata,
            samples: [sample(coldTTFT: 0.2, warmTTFT: 0.02), sample(coldTTFC: 3, warmTTFC: 0.3, coldTTFT: 0.6), sample()],
            attempted: 3, mlxPeakBytes: 1, processPeakBytes: 2)
        let decoded = try JSONDecoder().decode(ReleaseBenchmarkReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(try XCTUnwrap(decoded.coldTTFTMean), 0.4, accuracy: 0.0001)
        XCTAssertEqual(decoded.warmTTFTMean, 0.02)
        XCTAssertEqual(decoded.coldFirstTokenSamples, 2)
        XCTAssertEqual(decoded.warmFirstTokenSamples, 1)
        XCTAssertEqual(try XCTUnwrap(decoded.coldTTFCMean), 5.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(decoded.coldLatencySamples, 3)
    }
    func testLegacyReportDoesNotInferFirstTokenLatencyFromChunks() throws {
        let report = try ReleaseBenchmarkReport(metadata: metadata, samples: [sample()], attempted: 1,
                                                mlxPeakBytes: nil, processPeakBytes: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        json["schemaVersion"] = 1
        for key in ["coldTTFTMean", "warmTTFTMean", "coldFirstTokenSamples", "warmFirstTokenSamples"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ReleaseBenchmarkReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.coldTTFTMean); XCTAssertNil(decoded.warmTTFTMean)
        XCTAssertEqual(decoded.coldFirstTokenSamples, 0); XCTAssertEqual(decoded.warmFirstTokenSamples, 0)
        XCTAssertEqual(decoded.coldTTFCMean, 1)
    }
    func testInvalidFirstTokenMeasurementsCannotBecomeAReport() {
        for sample in [sample(coldTTFT: -.infinity), sample(warmTTFT: .nan), sample(coldTTFT: -0.1)] {
            XCTAssertThrowsError(try ReleaseBenchmarkReport(metadata: metadata, samples: [sample], attempted: 1,
                                                           mlxPeakBytes: nil, processPeakBytes: nil))
        }
    }
    func testInvalidMeasurementsCannotBecomeAReport() {
        for sample in [sample(coldTTFC: -.infinity), sample(warmTTFC: .nan), sample(prompt: 10, reused: 11), sample(prompt: -1, reused: 0)] {
            XCTAssertThrowsError(try ReleaseBenchmarkReport(metadata: metadata, samples: [sample], attempted: 1, mlxPeakBytes: nil, processPeakBytes: nil))
        }
        XCTAssertThrowsError(try ReleaseBenchmarkReport(metadata: metadata, samples: [sample()], attempted: 0, mlxPeakBytes: nil, processPeakBytes: nil))
    }
    func testExportRecordsMetadataWithoutOverwritingExistingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-Report-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report.json")
        let report = try ReleaseBenchmarkReport(metadata: metadata, samples: [sample()], attempted: 1, mlxPeakBytes: 123, processPeakBytes: 456)
        try report.write(to: file)
        let reopened = try JSONDecoder().decode(ReleaseBenchmarkReport.self, from: Data(contentsOf: file))
        XCTAssertEqual(reopened.metadata.revision, metadata.revision); XCTAssertEqual(reopened.metadata.toolchain, "Fixture Swift")
        XCTAssertEqual(reopened.processPeakBytes, 456)
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try report.write(to: file))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
