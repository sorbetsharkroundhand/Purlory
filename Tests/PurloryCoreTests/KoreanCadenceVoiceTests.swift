import Foundation
import XCTest
import PurloryKoreanBackend
@testable import PurloryCore
@testable import PurloryIntelligence

@MainActor final class KoreanCadenceVoiceTests: XCTestCase {
    private let cadence = "ko.style.cadence-variation", voice = "ko.style.voice-shift"
    func testCadenceNeedsEightCompletedNarrativeSentencesAndRespectsPreferences() async throws {
        let worker = KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL)
        let provider = KoreanDiagnosticsProvider(morphology: KoreanMorphology(worker: worker))
        let line = "바람은 조용히 불었다. "
        let text = String(repeating: line, count: 8)
        let findings = try await provider.analyze(request(text))
        let pattern = try XCTUnwrap(findings.first { $0.ruleID == cadence })
        XCTAssertEqual(pattern.relatedRanges.count, 7)
        XCTAssertEqual(pattern.severity, .suggestion)
        XCTAssertTrue(pattern.alternatives.isEmpty)
        for source in [String(repeating: line, count: 7), "“" + text + "”", "짧다. " + text] {
            try await quiet(provider, request(source), rule: cadence)
        }
        var disabled = request(text); disabled.styleProfile.ignoredRuleIDs.insert(cadence)
        try await quiet(provider, disabled, rule: cadence)
        disabled.styleProfile = .init(repetitionSensitivity: .off)
        try await quiet(provider, disabled, rule: cadence)
        await worker.release()
    }
    func testQuotedWhitespaceOffsetsFollowExactScalarTrimming() throws {
        let card = CharacterCard(name: "서연")
        for leading in ["\u{2028}", " \u{301}", "\t ", "\u{00A0}"] {
            let body = "서연이 말했다. “" + leading + "알겠어요.”"
            let utterance = try XCTUnwrap(DialogueAttribution.explicitUtterances(in: body, cards: [card]).first)
            let quoted = (body as NSString).substring(with: NSRange(location: utterance.utf16Start, length: utterance.text.utf16.count))
            XCTAssertTrue(quoted.utf16.elementsEqual(utterance.text.utf16), "Leading scalars: \(Array(leading.utf16))")
        }
    }

    func testExplicitSpeakerProofExcludesAlternationAmbiguityAndFutureNarration() throws {
        let a = CharacterCard(name: "서연"), b = CharacterCard(name: "민준")
        let body = "서연이 말했다. “  알겠어요. ”\n민준이 말했다. “괜찮아.”\n“그럼 가요.”\n서연이 민준을 보며 말했다. “기다려요.”\n서연희가 말했다. “아직이야.”"
        let utterances = try DialogueAttribution.explicitUtterances(in: body, cards: [a, b])
        XCTAssertEqual(utterances.count, 2)
        XCTAssertEqual(utterances.first?.speakerID, a.id)
        for value in utterances {
            XCTAssertEqual((body as NSString).substring(with: NSRange(location: value.utf16Start, length: value.text.utf16.count)), value.text)
        }
        let future = "“알겠어요.” 서연이 말했다."
        XCTAssertTrue(try DialogueAttribution.explicitUtterances(in: future, cards: [a], beforeUTF16: 8).isEmpty)
    }
    func testVoiceShiftUsesOnlyEarlierExplicitSamplesAndQuietlyRejectsShortOrUnknownSpeakers() async throws {
        let worker = KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL)
        let provider = KoreanDiagnosticsProvider(morphology: KoreanMorphology(worker: worker))
        let subject = WritingVoiceSubject(id: UUID(), name: "서연")
        let early = "서연이 말했다. “나는 오늘도 여기에서 기다립니다.”\n"
        let late = "서연이 말했다. “난 이제 저쪽으로 그냥 떠날래.”\n"
        let text = String(repeating: early, count: 8) + String(repeating: late, count: 4)
        var input = request(text); input.voiceSubjects = [subject]
        let findings = try await provider.analyze(input)
        let shift = try XCTUnwrap(findings.first { $0.ruleID == voice })
        XCTAssertGreaterThanOrEqual(shift.range.location, String(repeating: early, count: 8).utf16.count)
        XCTAssertTrue(shift.relatedRanges.allSatisfy { $0.nsRange.upperBound < shift.range.location })
        XCTAssertTrue(shift.reason?.contains("8") == true)
        for body in [String(repeating: early, count: 8) + String(repeating: late, count: 3), text.replacingOccurrences(of: "서연이 말했다. ", with: "")] {
            input.text = body
            try await quiet(provider, input, rule: voice)
        }
        input.text = text; input.styleProfile.dialogueSensitivity = .off
        try await quiet(provider, input, rule: voice)
        input.styleProfile = .init(ignoredRuleIDs: [voice])
        try await quiet(provider, input, rule: voice)
        await worker.release()
    }
    func testVoiceFingerprintCarriesAcrossBoundedWindowsAndCancellationCannotLeakSamples() async throws {
        let worker = KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL)
        let provider = KoreanDiagnosticsProvider(morphology: KoreanMorphology(worker: worker))
        let early = "서연이 말했다. “나는 오늘도 여기에서 기다립니다.”\n"
        let late = "서연이 말했다. “난 이제 저쪽으로 그냥 떠날래.”\n"
        var input = request(String(repeating: early, count: 8) + String(repeating: " \n", count: 1900) + String(repeating: late, count: 4))
        input.voiceSubjects = [.init(id: UUID(), name: "서연")]
        XCTAssertGreaterThan(input.text.utf16.count, 4096)
        let values = try await provider.analyze(input)
        let finding = try XCTUnwrap(values.first { $0.ruleID == voice })
        XCTAssertEqual(finding.relatedRanges.count, 11)
        for range in [finding.range] + finding.relatedRanges {
            XCTAssertTrue((input.text as NSString).substring(with: range.nsRange).hasPrefix("서연이 말했다."))
        }
        let cancelled = Task { try await provider.analyze(input) }; cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled fingerprint published") } catch is CancellationError { }
        input.text = late
        try await quiet(provider, input, rule: voice)
        await worker.release()
    }

    func testCadenceOwnershipSeamsAndVoiceSampleRetentionAreBounded() async throws {
        let worker = KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL)
        let morphology = KoreanMorphology(worker: worker)
        let text = String(repeating: "바람은 조용히 불었다. ", count: 8)
        let analysis = try await morphology.analyze(text)
        var baseline = KoreanRuleSession(profile: .init())
        let expected = baseline.consume(analysis, proseOffset: 0, final: true).filter { $0.ruleID == cadence }
        XCTAssertEqual(expected.count, 1)
        for seam in 1..<text.utf16.count {
            var session = KoreanRuleSession(profile: .init())
            var first = analysis; first.ownedRange = .init(location: 0, length: seam)
            var second = analysis; second.ownedRange = .init(location: seam, length: text.utf16.count - seam)
            let output = session.consume(first, proseOffset: 0, final: false) + session.consume(second, proseOffset: 0, final: true)
            XCTAssertEqual(output.filter { $0.ruleID == cadence }, expected)
        }
        let line = "서연이 말했다. “나는 오늘도 여기에서 기다립니다.”\n"
        let one = try await morphology.analyze(line)
        var voice = try KoreanVoiceSession(text: String(repeating: line, count: 100), subjects: [.init(id: UUID(), name: "서연")], profile: .init())
        for index in 0..<100 {
            XCTAssertTrue(try voice.consume(one, proseOffset: index * line.utf16.count).isEmpty)
            XCTAssertLessThanOrEqual(voice.retainedSampleCount, 12)
        }
        await worker.release()
    }

    private func quiet(_ provider: KoreanDiagnosticsProvider, _ request: WritingDiagnosticsRequest, rule: String) async throws {
        let values = try await provider.analyze(request)
        XCTAssertFalse(values.contains { $0.ruleID == rule })
    }
    private func request(_ text: String) -> WritingDiagnosticsRequest {
        .init(projectID: WritingProjectID(), documentID: WritingDocumentID(), text: text, languageTag: "ko", scope: .document)
    }
}
