@testable import PurloryIntelligence
import Foundation
import XCTest
import PurloryKoreanBackend
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class KoreanRepetitionTests: XCTestCase {
    func testInflectedFamiliesAndHomographs() async throws {
        try await withMorphology { morphology in
            for fixture in try fixtures() {
                let analysis = try await morphology.analyze(fixture.text)
                let findings = KoreanRepetitionRules.evaluate(analysis, profile: WritingStyleProfile())
                print("Korean repetition fixture: \(fixture.id), patterns \(findings.count)")
                for expected in fixture.required {
                    let matches = findings.filter { $0.ruleID == expected.ruleID }
                    XCTAssertEqual(matches.count, 1, fixture.id)
                    guard let finding = matches.first else { continue }
                    XCTAssertEqual(finding.relatedRanges.count + 1, expected.count, fixture.id)
                    let ranges = ([finding.range] + finding.relatedRanges).sorted { $0.location < $1.location }
                    XCTAssertEqual(Set(ranges).count, ranges.count)
                    for range in ranges {
                        XCTAssertGreaterThan(range.length, 0)
                        XCTAssertEqual((fixture.text as NSString).rangeOfComposedCharacterSequences(for: range.nsRange), range.nsRange)
                    }
                    if let expectedSurfaces = expected.surfaces {
                        let actual = ranges.map { (fixture.text as NSString).substring(with: $0.nsRange) }
                        XCTAssertEqual(actual.map { Array($0.utf16) }, expectedSurfaces.map { Array($0.utf16) }, fixture.id)
                    }
                    XCTAssertEqual(finding.severity, .suggestion)
                    XCTAssertEqual(finding.category, .style)
                    XCTAssertNil(finding.confidence)
                    XCTAssertTrue(finding.alternatives.isEmpty)
                    XCTAssertTrue(finding.reason?.contains(String(expected.count)) == true, fixture.id)
                }
                for rule in fixture.quiet { XCTAssertFalse(findings.contains { $0.ruleID == rule }, "\(fixture.id): \(rule)") }
            }
        }
    }

    func testSensitivityAndDialogueMatrix() async throws {
        let sentences = ["바람, 차갑다.", "바람, 낯설다.", "바람, 고요하다.", "바람, 아름답다."]
        try await withMorphology { morphology in
            for count in 2...4 {
                let analysis = try await morphology.analyze(sentences.prefix(count).joined(separator: " "))
                for (sensitivity, threshold) in [(WritingQualitySensitivity.off, Int.max), (.low, 4), (.standard, 3), (.high, 2)] {
                    let profile = WritingStyleProfile(repetitionSensitivity: sensitivity)
                    let words = KoreanRepetitionRules.evaluate(analysis, profile: profile).filter { $0.kind == .repeatedWord }
                    XCTAssertEqual(words.count, count >= threshold ? 1 : 0, "\(sensitivity), \(count)")
                }
            }
            for pair in [("“", "”"), ("\"", "\"")] {
                for count in 3...4 {
                    let text = pair.0 + sentences.prefix(count).joined(separator: " ") + pair.1
                    let analysis = try await morphology.analyze(text)
                    let fresh = KoreanRepetitionRules.evaluate(analysis, profile: WritingStyleRecord().profile).filter { $0.kind == .repeatedWord }
                    XCTAssertEqual(fresh.count, count == 4 ? 1 : 0, "New dialogue profile \(count)")
                    let legacy = KoreanRepetitionRules.evaluate(analysis, profile: WritingStyleProfile()).filter { $0.kind == .repeatedWord }
                    XCTAssertEqual(legacy.count, 1, "Explicit legacy standard dialogue \(count)")
                    let disabled = WritingStyleProfile(dialogueSensitivity: .off)
                    XCTAssertFalse(KoreanRepetitionRules.evaluate(analysis, profile: disabled).contains { $0.kind == .repeatedWord })
                }
            }
            let nested = "“바람, 차갑다. ‘바람, 낯설다.’ 바람, 고요하다. 바람, 아름답다.”"
            let analysis = try await morphology.analyze(nested)
            XCTAssertEqual(KoreanRepetitionRules.evaluate(analysis, profile: WritingStyleRecord().profile).filter { $0.kind == .repeatedWord }.count, 1)
            let separate = try await morphology.analyze("“바람.” “바람.” “바람.”")
            XCTAssertFalse(KoreanRepetitionRules.evaluate(separate, profile: WritingStyleProfile()).contains { $0.kind == .repeatedWord })
        }
    }

    func testParagraphBoundaryAndIntentionalRepetition() async throws {
        try await withMorphology { morphology in
            let body = "바람, 차갑다. 바람, 낯설다. 바람, 아름답다."
            let analysis = try await morphology.analyze(body)
            let pattern = try XCTUnwrap(KoreanRepetitionRules.evaluate(analysis, profile: WritingStyleProfile()).first { $0.kind == .repeatedWord })
            XCTAssertEqual(pattern.relatedRanges.count, 2)
            let identity = ProjectRuntimeIdentity(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1)
            let snapshot = ProjectDocumentSnapshot(identity: identity, title: "Synthetic rhetoric", body: body, kind: .manuscript, mode: .general)
            let intentional = try WritingStyleRepository.captureIntentional(ruleID: pattern.ruleID, range: pattern.range, in: snapshot)
            let evidence = EvidenceAnchor(documentID: identity.key.documentID,
                quote: (body as NSString).substring(with: pattern.range.nsRange), utf16Hint: pattern.range.location)
            XCTAssertTrue(intentional.suppresses(ruleID: pattern.ruleID, evidence: evidence, sourceRevision: intentional.sourceRevision))
            var ignored = WritingStyleProfile(); ignored.ignoredRuleIDs.insert(pattern.ruleID)
            XCTAssertFalse(KoreanRepetitionRules.evaluate(analysis, profile: ignored).contains { $0.ruleID == pattern.ruleID })
            let paragraphs = try await morphology.analyze(body.replacingOccurrences(of: ". ", with: ".\n"))
            XCTAssertTrue(KoreanRepetitionRules.evaluate(paragraphs, profile: WritingStyleProfile()).isEmpty)
        }
    }

    func testProviderComposesCorrectnessAndStyleWithoutRewriting() async throws {
        try await withMorphology { morphology in
            let provider = KoreanDiagnosticsProvider(morphology: morphology)
            let text = "그 일은 어제 됬다. 나는 밥을 먹었는데 비가 오는데 길이 어두운데 집으로 간다."
            var request = WritingDiagnosticsRequest(projectID: WritingProjectID(), documentID: WritingDocumentID(),
                text: text, languageTag: "ko", scope: .local)
            let findings = try await provider.analyze(request)
            XCTAssertTrue(findings.contains { $0.kind == .spelling && $0.severity == .correctness })
            XCTAssertTrue(findings.contains { $0.kind == .repeatedEnding && $0.severity == .suggestion })
            XCTAssertTrue(findings.filter { $0.category == .style }.allSatisfy { $0.alternatives.isEmpty })
            request.styleProfile.repetitionSensitivity = .off
            let off = try await provider.analyze(request)
            XCTAssertTrue(off.contains { $0.kind == .spelling })
            XCTAssertFalse(off.contains { $0.category == .style })
        }
    }

    func testNativeContextOwnershipAndLongRunsCannotDuplicatePatterns() async throws {
        try await withMorphology { morphology in
            let body = "바람, 차갑다. 바람, 낯설다. 바람, 아름답다."
            let analysis = try await morphology.analyze(body)
            let ns = body as NSString
            let second = ns.range(of: "바람", range: NSRange(location: 2, length: ns.length - 2))
            let shadow = KoreanAnalysisSlice(range: .init(location: 0, length: ns.length), ownership: .init(location: 0, length: 0),
                tokens: [.init(form: "다", tag: "EF", range: .init(location: second.location + 1, length: 1))], candidates: [])
            let withUnowned = KoreanAnalysis(text: analysis.text, tokens: analysis.tokens, sentences: analysis.sentences,
                candidates: analysis.candidates, slices: analysis.slices + [shadow], unsupportedRanges: analysis.unsupportedRanges)
            let base = KoreanRepetitionRules.evaluate(analysis, profile: WritingStyleProfile()).filter { $0.kind == .repeatedWord }
            let guarded = KoreanRepetitionRules.evaluate(withUnowned, profile: WritingStyleProfile()).filter { $0.kind == .repeatedWord }
            XCTAssertEqual(guarded.map(\.range), base.map(\.range), "Unowned context cannot introduce a clause boundary")
            for padding in [759, 760, 880, 887, 895] {
                let text = String(repeating: " ", count: padding) + body
                let context = try await morphology.analyze(text)
                let words = KoreanRepetitionRules.evaluate(context, profile: WritingStyleProfile()).filter { $0.kind == .repeatedWord }
                XCTAssertEqual(words.count, 1, "Native context boundary \(padding)")
                XCTAssertEqual(words.first?.relatedRanges.count, 2)
            }
            let long = String(repeating: "바람, 차갑다. ", count: 400)
            let all = try await morphology.analyze(long)
            let patterns = KoreanRepetitionRules.evaluate(all, profile: WritingStyleProfile()).filter {
                $0.kind == .repeatedWord && (long as NSString).substring(with: $0.range.nsRange) == "바람"
            }
            XCTAssertEqual(patterns.count, 1, "One adjacent run produces one pattern")
            XCTAssertEqual(patterns.first?.relatedRanges.count, 399)
        }
    }

    private struct Fixture: Decodable {
        struct Required: Decodable { let ruleID: String; let count: Int; let surfaces: [String]? }
        let id: String; let text: String; let required: [Required]; let quiet: [String]
    }
    private func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "repetition", withExtension: "json", subdirectory: "KoreanDiagnostics"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }
    private func withMorphology(_ body: (KoreanMorphology) async throws -> Void) async throws {
        let worker = KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL)
        do { try await body(KoreanMorphology(worker: worker)); await worker.release() }
        catch { await worker.release(); throw error }
    }
}
