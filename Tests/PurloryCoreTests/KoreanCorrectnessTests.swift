@testable import PurloryIntelligence
import Foundation
import XCTest
import PurloryKoreanBackend
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class KoreanCorrectnessTests: XCTestCase {
    func testUnambiguousTypoAndMorphologicalSpacing() async throws {
        try await withProvider { _, provider in
            for fixture in try fixtures().filter({ !$0.expected.isEmpty && !$0.id.hasPrefix("nfd") && $0.id != "mixed" }) {
                try await verify(fixture, provider: provider)
            }
        }
    }

    func testAmbiguousFictionAndLearnedNamesRemainSuggestionsOrQuiet() async throws {
        try await withProvider { _, provider in
            for fixture in try fixtures().filter({ $0.expected.isEmpty }) {
                let findings = try await provider.analyze(request(fixture.text))
                print("Korean correctness fixture: \(fixture.id), expected 0, actual \(findings.filter { $0.severity == .correctness }.count)")
                XCTAssertFalse(findings.contains { $0.severity == .correctness }, fixture.id)
            }
            var profile = WritingStyleProfile(learnedWords: ["됬다", "할수"])
            let learned = try await provider.analyze(request("그 일은 어제 됬다. 나는 할수 있다.", profile: profile))
            XCTAssertTrue(learned.isEmpty)
            profile.learnedWords = ["됬", "수"] // Substrings must not suppress a different lexical entry.
            let notLearned = try await provider.analyze(request("그 일은 어제 됬다.", profile: profile))
            XCTAssertEqual(notLearned.filter { $0.severity == .correctness }.count, 1)
            profile.learnedWords = ["있다"]
            let unrelatedLearned = try await provider.analyze(request("나는 할수 있다.", profile: profile))
            XCTAssertEqual(unrelatedLearned.count, 1, "An unchanged learned predicate must not hide a different lexical error")
        }
    }

    func testMixedAndDecomposedOffsetsStayOriginal() async throws {
        try await withProvider { _, provider in
            for fixture in try fixtures().filter({ $0.id == "mixed" || $0.id.hasPrefix("nfd") }) {
                try await verify(fixture, provider: provider)
            }
        }
    }

    func testNativeCallsAreBoundedInsideAnAnalysisWindowAndCancellationSurvives() async throws {
        try await withProvider { morphology, provider in
            let text = String(repeating: "문장이다. ", count: 500) + "그 일은 어제 됬다."
            XCTAssertLessThanOrEqual(text.utf16.count, 4096)
            let analysis = try await morphology.analyze(text)
            XCTAssertFalse(analysis.tokens.isEmpty)
            for token in analysis.tokens {
                XCTAssertGreaterThanOrEqual(token.range.location, 0)
                XCTAssertLessThanOrEqual(token.range.location + token.range.length, text.utf16.count)
            }
            let findings = try await provider.analyze(request(text))
            XCTAssertEqual(findings.filter { $0.kind == .spelling }.count, 1)
            for invalid in [String(repeating: "가", count: 4097), "한글\0뒤"] {
                do { _ = try await morphology.analyze(invalid); XCTFail("Invalid input admitted") } catch {}
            }
            let task = Task { try await morphology.analyze("나는 할수 있다.") }
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled analysis published") } catch {}
        }
    }

    func testUnsupportedLanguageDoesNotRequireBackendResources() async throws {
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/missing-synthetic-korean-resources"))
        let provider = KoreanDiagnosticsProvider(morphology: KoreanMorphology(worker: worker))
        var input = request("그 일은 어제 됬다."); input.languageTag = "en"
        let findings = try await provider.analyze(input)
        XCTAssertTrue(findings.isEmpty)
        await worker.release()
    }

    func testOversizedComposedInputCannotReportCleanSuccess() async throws {
        try await withProvider { morphology, provider in
            let text = "가" + String(repeating: "\u{0301}", count: 2_000) + " 뒤"
            let analysis = try await morphology.analyze(text)
            XCTAssertFalse(analysis.unsupportedRanges.isEmpty)
            XCTAssertTrue(analysis.tokens.contains { $0.form == "뒤" })
            do { _ = try await provider.analyze(request(text)); XCTFail("Unassessed text was reported as provider success") } catch {}
        }
    }

    func testMalformedNativeRangesAreRejectedBeforeClamping() throws {
        for range in [NSRange(location: -1, length: 1), NSRange(location: 0, length: Int.max), NSRange(location: 1, length: 1)] {
            let native = KoreanNativeAnalysis(tokens: [.init(form: "bad", tag: "NNG", range: range)], sentences: [], candidates: [])
            XCTAssertThrowsError(try KoreanMorphology.convert(native, text: "🙂"))
        }
        let virtual = KoreanNativeAnalysis(tokens: [.init(form: "ᆯ", tag: "ETM", range: NSRange(location: 0, length: 0))], sentences: [], candidates: [])
        XCTAssertEqual(try KoreanMorphology.convert(virtual, text: "할").tokens.first?.range.length, 0)
        let malformed = KoreanNativeAnalysis(tokens: [], sentences: [], candidates: [
            .init(originalRange: NSRange(location: 0, length: 3), replacement: "bad", origin: "kiwi.join")])
        XCTAssertThrowsError(try KoreanMorphology.convert(malformed, text: "가"))
        XCTAssertThrowsError(try KoreanMorphology.convert(virtual, text: "할", offset: Int.max))
    }

    func testOwnedNativeBoundaryDoesNotDropOrDuplicateCorrections() async throws {
        try await withProvider { _, provider in
            for prefix in [759, 760, 761, 887] {
                let input = String(repeating: " ", count: prefix) + "그 일은 어제 됬다."
                let findings = try await provider.analyze(request(input))
                XCTAssertEqual(findings.count, 1, "Native context boundary \(prefix)")
                XCTAssertEqual(findings.first?.range, .init(location: prefix + 8, length: 2))
            }
            let ignored = WritingStyleProfile(ignoredRuleIDs: ["ko.correctness.doeda-past"], dialogueSensitivity: .off)
            let ignoredFindings = try await provider.analyze(request("그 일은 어제 됬다.", profile: ignored))
            XCTAssertTrue(ignoredFindings.isEmpty)
            let dialogueOff = WritingStyleProfile(dialogueSensitivity: .off)
            let correctness = try await provider.analyze(request("“그 일은 어제 됬다.”", profile: dialogueOff))
            XCTAssertEqual(correctness.count, 1, "Dialogue style preference must not disable correctness")
        }
    }

    private func verify(_ fixture: Fixture, provider: KoreanDiagnosticsProvider) async throws {
        let findings = try await provider.analyze(request(fixture.text))
        let correct = findings.filter { $0.severity == .correctness }
        print("Korean correctness fixture: \(fixture.id), expected \(fixture.expected.count), actual \(correct.count)")
        XCTAssertEqual(correct.count, fixture.expected.count, fixture.id)
        for expected in fixture.expected {
            guard let finding = correct.first(where: {
                $0.kind.rawValue == expected.kind
                    && $0.range.location == expected.location && $0.range.length == expected.length
            }) else { XCTFail("Missing required original span: \(fixture.id)"); continue }
            XCTAssertTrue((fixture.text as NSString).substring(with: finding.range.nsRange).utf16.elementsEqual(expected.original.utf16), fixture.id)
            XCTAssertEqual(finding.alternatives, [expected.replacement], fixture.id)
            XCTAssertNil(finding.confidence, "No calibrated confidence is claimed")
            XCTAssertEqual((fixture.text as NSString).rangeOfComposedCharacterSequences(for: finding.range.nsRange), finding.range.nsRange)
        }
        XCTAssertEqual(Set(findings.map(\.id)).count, findings.count)
    }
    private func request(_ text: String, profile: WritingStyleProfile = WritingStyleProfile()) -> WritingDiagnosticsRequest {
        .init(projectID: WritingProjectID(), documentID: WritingDocumentID(), text: text,
              languageTag: "ko", scope: .local, styleProfile: profile)
    }
    private func withProvider(_ body: (KoreanMorphology, KoreanDiagnosticsProvider) async throws -> Void) async throws {
        let worker = KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL)
        let morphology = KoreanMorphology(worker: worker), provider = KoreanDiagnosticsProvider(morphology: morphology)
        do { try await body(morphology, provider); await worker.release() }
        catch { await worker.release(); throw error }
    }
    private struct Fixture: Decodable {
        struct Expected: Decodable {
            let original: String; let replacement: String; let kind: String
            let location: Int; let length: Int
        }
        let id: String; let text: String; let expected: [Expected]
    }
    private func fixtures() throws -> [Fixture] {
        let path = try XCTUnwrap(Bundle.module.url(forResource: "correctness", withExtension: "json", subdirectory: "KoreanDiagnostics"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: path))
    }
}
