@testable import PurloryIntelligence
import Foundation
import XCTest
import PurloryKoreanBackend
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class KoreanSentenceRulesTests: XCTestCase {
    func testCausalTransitionChainStartAndLengthBoundaries() async throws {
        try await withMorphology { morphology in
            for fixture in try fixtures() {
                let analysis = try await morphology.analyze(fixture.text)
                var session = KoreanRuleSession(profile: WritingStyleProfile())
                let findings = session.consume(analysis, proseOffset: 0, final: true)
                print("Korean sentence fixture: \(fixture.id), rules \(findings.map(\.ruleID))")
                for rule in fixture.required {
                    let matches = findings.filter { $0.ruleID == rule }
                    XCTAssertEqual(matches.count, 1, "\(fixture.id): \(rule)")
                    for finding in matches {
                        XCTAssertNil(finding.confidence)
                        XCTAssertTrue(finding.alternatives.isEmpty)
                        XCTAssertNotNil(finding.reason)
                        for range in [finding.range] + finding.relatedRanges {
                            XCTAssertGreaterThan(range.length, 0)
                            XCTAssertEqual((fixture.text as NSString).rangeOfComposedCharacterSequences(for: range.nsRange), range.nsRange)
                        }
                    }
                }
                for rule in fixture.quiet { XCTAssertFalse(findings.contains { $0.ruleID == rule }, fixture.id) }
                if fixture.id == "sentence-starts" {
                    let finding = try XCTUnwrap(findings.first { $0.kind == .repeatedSentenceStart })
                    XCTAssertEqual((fixture.text as NSString).substring(with: finding.range.nsRange), "그 사람")
                    XCTAssertTrue(finding.reason?.contains("그 사람") == true)
                    XCTAssertEqual(finding.relatedRanges.count, 2)
                }
            }
        }
        var lengthCounts: [Int] = []
        for count in [119, 120] {
            let text = String(repeating: "가", count: count) + "."
            let analysis = pureAnalysis(text, tokens: [token("가", "NNG", 0, count), token(".", "SF", count, 1)])
            var session = KoreanRuleSession(profile: WritingStyleProfile())
            let lengths = session.consume(analysis, proseOffset: 0, final: true).filter { $0.kind == .sentenceLength }
            lengthCounts.append(lengths.count)
            if let finding = lengths.first { XCTAssertEqual(finding.range.length, 121); XCTAssertEqual(finding.severity, .info) }
        }
        XCTAssertEqual(lengthCounts, [0, 1])
    }

    func testChunkBoundaryDoesNotChangeReport() async throws {
        try await withMorphology { morphology in
            for body in ["문을 열어서 그래서 길을 건너고 돌아서 집에 갔다.",
                         "그 사람은 걸었다. 그 사람은 웃었다. 그 사람은 떠났다.",
                         "“바람, 차갑다. ‘바람, 낯설다.’ 바람, 고요하다. 바람, 아름답다.”"] {
                let analysis = try await morphology.analyze(body), length = body.utf16.count
                var reference = KoreanRuleSession(profile: WritingStyleProfile())
                let expected = canonical(reference.consume(analysis, proseOffset: 0, final: true))
                for seam in 1..<length {
                    let ns = body as NSString
                    guard ns.rangeOfComposedCharacterSequence(at: seam).location == seam else { continue }
                    var session = KoreanRuleSession(profile: WritingStyleProfile())
                    var actual = session.consume(chunk(analysis, owning: NSRange(location: 0, length: seam)), proseOffset: 0, final: false)
                    let tail = chunk(analysis, owning: NSRange(location: seam, length: length - seam))
                    let offset = max(0, seam - 128)
                    actual += session.consume(tail, proseOffset: offset, final: true)
                    XCTAssertEqual(canonical(actual), expected, "Boundary \(seam): \(body)")
                }
            }
        }
    }

    func testSessionResetCannotLeakQuoteOrPatternState() async throws {
        try await withMorphology { morphology in
            let old = try await morphology.analyze("“그 사람은 걸었다. 그 사람은 웃었다.")
            var session = KoreanRuleSession(profile: WritingStyleProfile())
            _ = session.consume(old, proseOffset: 0, final: false)
            session.reset()
            let fresh = try await morphology.analyze("그 사람은 떠났다.")
            let findings = session.consume(fresh, proseOffset: 0, final: true)
            XCTAssertTrue(findings.isEmpty)
            let quoted = try await morphology.analyze("“문을 열어서 그래서 길을 건너고 돌아서 집에 갔다.”")
            var disabled = KoreanRuleSession(profile: WritingStyleProfile(dialogueSensitivity: .off))
            XCTAssertTrue(disabled.consume(quoted, proseOffset: 0, final: true).filter { $0.category == .style }.isEmpty)
            let correct = try await morphology.analyze("“됬다.”")
            var correctness = KoreanRuleSession(profile: WritingStyleProfile(dialogueSensitivity: .off))
            XCTAssertTrue(correctness.consume(correct, proseOffset: 0, final: true).contains { $0.kind == .spelling })
        }
    }

    func testDocumentProviderStreamsOwnedChunksAndCancellation() async throws {
        try await withMorphology { morphology in
            let provider = KoreanDiagnosticsProvider(morphology: morphology)
            let body = "문을 열어서 그래서 길을 건너고 돌아서 집에 갔다. 그 사람은 걸었다. 그 사람은 웃었다. 그 사람은 떠났다."
            let text = String(repeating: " ", count: 3950) + body + String(repeating: " ", count: 400)
            let request = WritingDiagnosticsRequest(projectID: WritingProjectID(), documentID: WritingDocumentID(), text: text, languageTag: "ko", scope: .document)
            let sink = ChunkSink()
            try await provider.analyzeChunks(request) { chunk in await sink.append(chunk) }
            let chunks = await sink.values
            XCTAssertGreaterThan(chunks.count, 1)
            var cursor = 0
            for chunk in chunks {
                XCTAssertEqual(chunk.assessedRange.location, cursor)
                XCTAssertLessThanOrEqual(chunk.assessedRange.length, 4096)
                XCTAssertEqual(chunk.totalProseUTF16, text.utf16.count)
                XCTAssertTrue(chunk.unsupportedRanges.isEmpty)
                cursor += chunk.assessedRange.length
            }
            XCTAssertEqual(cursor, text.utf16.count)
            let all = chunks.flatMap(\.diagnostics)
            XCTAssertEqual(Set(all.map(\.id)).count, all.count)
            let analysis = try await morphology.analyze(body)
            var reference = KoreanRuleSession(profile: WritingStyleProfile())
            let expected = reference.consume(analysis, proseOffset: 0, final: true).map { finding in
                var value = finding; value.range.location += 3950
                value.relatedRanges = value.relatedRanges.map { .init(location: $0.location + 3950, length: $0.length) }
                return value
            }
            XCTAssertEqual(canonicalEvidence(all), canonicalEvidence(expected))
            let collected = try await provider.analyze(request)
            XCTAssertEqual(canonical(collected), canonical(all))
            let cancelled = Task {
                try await provider.analyzeChunks(request) { _ in throw CancellationError() }
            }
            do { try await cancelled.value; XCTFail("Consumer cancellation must stop the report") }
            catch is CancellationError { }
            let fresh = try await provider.analyze(.init(projectID: WritingProjectID(), documentID: WritingDocumentID(), text: "바람이 분다.", languageTag: "ko"))
            XCTAssertTrue(fresh.isEmpty, "A cancelled report session cannot leak patterns")
        }
    }

    func testLongSentenceAnd300kParagraphRetainBoundedState() {
        let count = 75_000, unit = "바람, "
        let text = String(repeating: unit, count: count) + "끝났다."
        let length = text.utf16.count
        var tokens = (0..<count).map { token("바람", "NNG", $0 * 4, 2) }
        tokens += [token("끝나", "VV", length - 4, 2), token("다", "EF", length - 2, 1), token(".", "SF", length - 1, 1)]
        let analysis = pureAnalysis(text, tokens: tokens)
        var reference = KoreanRuleSession(profile: WritingStyleProfile())
        let expected = reference.consume(analysis, proseOffset: 0, final: true)
        var session = KoreanRuleSession(profile: WritingStyleProfile()), actual: [WritingDiagnostic] = []
        var cursor = 0
        while cursor < length {
            let end = min(length, cursor + 3840)
            let window = chunk(analysis, owning: NSRange(location: cursor, length: end - cursor))
            actual += session.consume(window, proseOffset: max(0, cursor - 128), final: end == length)
            XCTAssertLessThan(session.retainedOccurrenceCount, 20)
            XCTAssertLessThan(session.retainedTextUTF16, 256)
            XCTAssertLessThanOrEqual(session.retainedQuoteDepth, KoreanRuleSession.maximumQuoteDepth)
            cursor = end
        }
        XCTAssertEqual(canonical(actual), canonical(expected))
        let long = actual.filter { $0.kind == .sentenceLength }
        XCTAssertEqual(long.count, 1)
        XCTAssertEqual(long.first?.range.length, length)
    }

    func testMalformedOwnershipAndPathologicalQuoteDepthAreExplicitlyUnsupported() {
        var invalid = pureAnalysis("😀", tokens: [])
        invalid.ownedRange = .init(location: 0, length: 1)
        var session = KoreanRuleSession(profile: WritingStyleProfile())
        XCTAssertTrue(session.consume(invalid, proseOffset: 0, final: true).isEmpty)
        XCTAssertFalse(session.acceptsInput, "Half a grapheme cannot become assessed coverage")
        session.reset()
        XCTAssertTrue(session.acceptsInput)
        let text = String(repeating: "“", count: 40) + "바람" + String(repeating: "”", count: 40)
        XCTAssertTrue(session.consume(pureAnalysis(text, tokens: []), proseOffset: 0, final: true).isEmpty)
        XCTAssertLessThanOrEqual(session.retainedQuoteDepth, KoreanRuleSession.maximumQuoteDepth)
        XCTAssertEqual(session.unsupportedRanges.first?.location, KoreanRuleSession.maximumQuoteDepth)
        XCTAssertEqual(session.unsupportedRanges.reduce(0) { $0 + $1.length }, text.utf16.count - KoreanRuleSession.maximumQuoteDepth)
        XCTAssertEqual(session.unsupportedRanges.count, 1)
    }

    func testFamilyOverflowIsPartialAndDoesNotGrowWithAClause() {
        let count = KoreanRuleSession.maximumFamilies + 200
        let text = String(repeating: "가 ", count: count)
        let tokens = (0..<count).map { token("synthetic-lemma-\($0)", "NNG", $0 * 2, 1) }
        let analysis = pureAnalysis(text, tokens: tokens)
        var session = KoreanRuleSession(profile: WritingStyleProfile())
        let findings = session.consume(analysis, proseOffset: 0, final: true)
        XCTAssertTrue(findings.isEmpty)
        XCTAssertFalse(session.unsupportedRanges.isEmpty)
        XCTAssertLessThanOrEqual(session.retainedOccurrenceCount, KoreanRuleSession.maximumFamilies * 5 + 10)
    }

    func testCorrectnessAcrossReportOwnershipSeamsKeepsExactOriginalRanges() async throws {
        try await withMorphology { morphology in
            let provider = KoreanDiagnosticsProvider(morphology: morphology)
            for seam in [3965, 3967, 3968, 3969, 3971] {
                for spelling in ["됬다", "됬다".decomposedStringWithCanonicalMapping] {
                    let text = String(repeating: " ", count: seam) + "그 일은 어제 " + spelling + ". 그 일은 오늘 " + spelling + "." + String(repeating: " ", count: 400)
                    let findings = try await provider.analyze(.init(projectID: WritingProjectID(), documentID: WritingDocumentID(), text: text, languageTag: "ko", scope: .document)).filter { $0.kind == .spelling }
                    XCTAssertEqual(findings.count, 2, "\(seam), original \(Array(spelling.utf16))")
                    let expected = (text as NSString).ranges(of: spelling)
                    XCTAssertEqual(findings.map(\.range.nsRange), expected)
                    for finding in findings {
                        XCTAssertEqual(Array((text as NSString).substring(with: finding.range.nsRange).utf16), Array(spelling.utf16))
                        XCTAssertEqual(finding.alternatives, ["됐다"])
                    }
                }
            }
        }
    }

    func testRealReportPatternOwnershipMatrixAndNestedASCIIQuotes() async throws {
        try await withMorphology { morphology in
            let provider = KoreanDiagnosticsProvider(morphology: morphology)
            let bodies = ["그 사람은 걸었다. 그 사람은 웃었다. 그 사람은 떠났다.",
                          "문을 열어서 그래서 길을 건너고 돌아서 집에 갔다.",
                          "“바람, 차갑다. \"바람, 낯설다.\" 바람, 고요하다. 바람, 아름답다.”"]
            for body in bodies {
                let analysis = try await morphology.analyze(body)
                var baseline = KoreanRuleSession(profile: WritingStyleProfile())
                let reference = baseline.consume(analysis, proseOffset: 0, final: true)
                XCTAssertFalse(reference.isEmpty)
                for padding in [3930, 3947, 3960, 3970] {
                    let text = String(repeating: " ", count: padding) + body + String(repeating: " ", count: 400)
                    let actual = try await provider.analyze(.init(projectID: WritingProjectID(), documentID: WritingDocumentID(), text: text, languageTag: "ko", scope: .document))
                    let expected = reference.map { finding in
                        var result = finding; result.range.location += padding
                        result.relatedRanges = result.relatedRanges.map { .init(location: $0.location + padding, length: $0.length) }
                        return result
                    }
                    XCTAssertEqual(canonicalEvidence(actual), canonicalEvidence(expected), "\(padding): \(body)")
                }
            }
            let ignored = WritingStyleProfile(ignoredRuleIDs: ["ko.style.redundant-causality", "ko.style.connective-chain"])
            var session = KoreanRuleSession(profile: ignored)
            let analysis = try await morphology.analyze(bodies[1])
            let findings = session.consume(analysis, proseOffset: 0, final: true)
            XCTAssertFalse(findings.contains { [.redundantConnector, .connectiveChain].contains($0.kind) })
        }
    }

    func testRealLongSentenceCrosses4096WithoutResettingClauseOrRunCounts() async throws {
        try await withMorphology { morphology in
            let text = String(repeating: "문을 열고 ", count: 700) + "집에 갔다."
            XCTAssertGreaterThan(text.utf16.count, 4096)
            let provider = KoreanDiagnosticsProvider(morphology: morphology)
            let findings = try await provider.analyze(.init(projectID: WritingProjectID(), documentID: WritingDocumentID(), text: text, languageTag: "ko", scope: .document))
            let chains = findings.filter { $0.kind == .connectiveChain }, lengths = findings.filter { $0.kind == .sentenceLength }
            XCTAssertEqual(chains.count, 1); XCTAssertEqual(lengths.count, 1)
            XCTAssertEqual(chains.first?.range, .init(location: 0, length: text.utf16.count))
            XCTAssertTrue(chains.first?.reason?.contains("701") == true)
            XCTAssertEqual(lengths.first?.range, chains.first?.range)
            let repeated = findings.filter { $0.kind == .repeatedWord && (text as NSString).substring(with: $0.range.nsRange) == "문" }
            XCTAssertEqual(repeated.count, 1)
            XCTAssertEqual(repeated.first?.relatedRanges.count, 2, "Streaming evidence is bounded at the standard threshold")
            XCTAssertTrue(repeated.first?.reason?.contains("700") == true)
            XCTAssertEqual(repeated.first?.relatedRanges.map(\.location), [697 * "문을 열고 ".utf16.count, 698 * "문을 열고 ".utf16.count], "Carry the most recent threshold-sized evidence")
        }
    }

    func testGenericCollectionCannotClaimCompleteOnUnassessedStyle() async throws {
        try await withMorphology { morphology in
            let provider = KoreanDiagnosticsProvider(morphology: morphology)
            let text = String(repeating: "“", count: 40) + "바람이 분다." + String(repeating: "”", count: 40)
            let request = WritingDiagnosticsRequest(projectID: WritingProjectID(), documentID: WritingDocumentID(), text: text, languageTag: "ko", scope: .document)
            let sink = ChunkSink()
            try await provider.analyzeChunks(request) { await sink.append($0) }
            let chunks = await sink.values
            XCTAssertTrue(chunks.contains { !$0.unsupportedRanges.isEmpty })
            do { _ = try await provider.analyze(request); XCTFail("A protocol returning only findings must fail closed on partial coverage") }
            catch KoreanMorphologyError.unsupportedInput { }
        }
    }

    private func canonicalEvidence(_ findings: [WritingDiagnostic]) -> [String] {
        findings.map { "\($0.ruleID):\($0.range):\($0.relatedRanges):\($0.reason ?? "")" }.sorted()
    }
    private actor ChunkSink {
        var values: [KoreanDiagnosticsChunk] = []
        func append(_ chunk: KoreanDiagnosticsChunk) { values.append(chunk) }
    }

    private func canonical(_ findings: [WritingDiagnostic]) -> [WritingDiagnostic] { findings.sorted { $0.id < $1.id } }
    private func token(_ form: String, _ tag: String, _ offset: Int, _ length: Int) -> KoreanToken {
        .init(form: form, tag: tag, range: .init(location: offset, length: length))
    }
    private func pureAnalysis(_ text: String, tokens: [KoreanToken]) -> KoreanAnalysis {
        .init(text: text, tokens: tokens, sentences: [], candidates: [],
              slices: [.init(range: .init(location: 0, length: text.utf16.count), ownership: .init(location: 0, length: text.utf16.count), tokens: tokens, candidates: [])], unsupportedRanges: [])
    }
    private func chunk(_ analysis: KoreanAnalysis, owning owned: NSRange) -> KoreanAnalysis {
        let ns = analysis.text as NSString, start = max(0, owned.location - 128), end = min(ns.length, owned.upperBound + 128)
        let range = NSRange(location: start, length: end - start)
        let tokens = analysis.tokens.filter { $0.range.location >= start && $0.range.nsRange.upperBound <= end }.map {
            KoreanToken(form: $0.form, tag: $0.tag, range: .init(location: $0.range.location - start, length: $0.range.length))
        }
        var result = pureAnalysis(ns.substring(with: range), tokens: tokens)
        result.ownedRange = .init(location: owned.location - start, length: owned.length)
        return result
    }
    private struct Fixture: Decodable { let id: String; let text: String; let required: [String]; let quiet: [String] }
    private func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sentence-flow", withExtension: "json", subdirectory: "KoreanDiagnostics"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }
    private func withMorphology(_ body: (KoreanMorphology) async throws -> Void) async throws {
        let worker = KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL)
        do { try await body(KoreanMorphology(worker: worker)); await worker.release() }
        catch { await worker.release(); throw error }
    }
}

private extension NSString {
    func ranges(of needle: String) -> [NSRange] {
        var cursor = 0, result: [NSRange] = []
        while cursor < length {
            let match = range(of: needle, range: NSRange(location: cursor, length: length - cursor))
            guard match.location != NSNotFound else { break }
            result.append(match); cursor = match.upperBound
        }
        return result
    }
}
