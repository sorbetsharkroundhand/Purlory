import CryptoKit
import Foundation
import PurloryFoundation
import PurloryDocumentEngine
import PurloryIntelligence

/// Prepared values only: presentation never owns analysis, source scanning or navigation.
enum WritingDiagnosticsPresentation {
    enum Operation { case apply(Int), intentional, disableRule, learnWord(String) }
    struct Binding { let action: MarginAction; let operation: Operation }

    static func insights(from state: WritingDiagnosticsState) -> [MarginInsight] {
        state.findings.compactMap { insight(for: $0) }
    }
    static func insight(for finding: WritingDiagnosticsFinding) -> MarginInsight? {
        let diagnostic = finding.diagnostic
        guard diagnostic.severity != .info || !diagnostic.alternatives.isEmpty,
              !finding.evidence.quote.isEmpty else { return nil }
        if let confidence = diagnostic.confidence {
            guard confidence.isFinite, confidence >= LivingMarginPolicy.minimumVisibleConfidence else { return nil }
        }
        var message = diagnostic.message
        if let reason = diagnostic.reason, !reason.isEmpty, reason != message { message += "\n" + reason }
        return MarginInsight(id: "writing-quality:" + finding.id, kind: .writingQuality, title: title(for: diagnostic.kind),
            message: message, evidence: [finding.evidence] + finding.relatedEvidence,
            confidence: diagnostic.confidence, actions: bindings(for: finding).map(\.action))
    }
    static func bindings(for finding: WritingDiagnosticsFinding) -> [Binding] {
        var values: [Binding] = []
        let stamp = finding.stamp
        var baseHasher = SHA256()
        updateHasher(&baseHasher, string: finding.id)
        updateHasher(&baseHasher, string: stamp.runtime.key.projectID.rawValue.uuidString)
        updateHasher(&baseHasher, string: stamp.runtime.key.documentID.rawValue.uuidString)
        updateHasher(&baseHasher, uint64: stamp.runtime.generation)
        updateHasher(&baseHasher, uint64: stamp.nativeRevision)
        updateHasher(&baseHasher, uint64: stamp.profileRevision)
        updateHasher(&baseHasher, string: stamp.providerRevision)
        updateHasher(&baseHasher, uint64: UInt64(bitPattern: Int64(stamp.ruleRevision)))
        updateHasher(&baseHasher, string: stamp.windowDigest)
        func add(_ operation: Operation, verb: String, payload: String = "", kind: MarginAction.Kind = .custom, title: String) {
            var hasher = baseHasher
            updateHasher(&hasher, string: verb)
            updateHasher(&hasher, string: payload)
            let digest = hexString(hasher.finalize())
            values.append(.init(action: .init(id: "writing-action:" + digest, kind: kind, title: title), operation: operation))
        }
        for (index, alternative) in finding.diagnostic.alternatives.enumerated() {
            add(.apply(index), verb: "apply", payload: alternative, title: "‘\(alternative)’로 고치기")
        }
        if finding.diagnostic.category != .correctness {
            add(.intentional, verb: "intentional", kind: .markIntentional, title: "의도한 표현")
        }
        add(.disableRule, verb: "disable", title: "이 검사 끄기")
        if finding.diagnostic.category == .correctness, let word = learnableWord(finding.evidence.quote) {
            add(.learnWord(word), verb: "learn", payload: word, title: "‘\(word)’ 기억하기")
        }
        return values
    }
    private static func updateHasher(_ hasher: inout SHA256, uint64 value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
    }
    private static func updateHasher(_ hasher: inout SHA256, string value: String) {
        var utf8 = value
        utf8.withUTF8 { buffer in
            updateHasher(&hasher, uint64: UInt64(buffer.count))
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
    }
    private static func hexString(_ digest: SHA256Digest) -> String {
        let hex: StaticString = "0123456789abcdef"
        return String(unsafeUninitializedCapacity: 64) { out in
            hex.withUTF8Buffer { table in
                var i = 0
                for byte in digest {
                    out[i] = table[Int(byte >> 4)]
                    out[i + 1] = table[Int(byte & 0x0F)]
                    i += 2
                }
            }
            return 64
        }
    }
    static func learnableWord(_ original: String) -> String? {
        let word = original.precomposedStringWithCanonicalMapping
        let allowed = CharacterSet.letters.union(.nonBaseCharacters).union(.decimalDigits)
        guard !word.isEmpty, word.utf16.count <= 128, word.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return word
    }
    private static func title(for kind: WritingDiagnosticKind) -> String {
        switch kind {
        case .spelling: "맞춤법"
        case .spacing: "띄어쓰기"
        case .grammar: "문장 표현"
        case .repeatedWord: "반복되는 단어"
        case .repeatedParticle: "반복되는 조사"
        case .repeatedEnding: "반복되는 어미"
        case .repeatedConnector, .redundantConnector: "이어 주는 표현"
        case .connectiveChain: "이어지는 문장"
        case .repeatedSentenceStart: "반복되는 문장 시작"
        case .sentenceLength: "문장 길이"
        case .sentenceRhythm: "문장 리듬"
        case .cadenceVariation: "문장 길이 변주"
        case .characterVoice: "인물 말투"
        case .vagueWord, .overusedWord, .wordAlternative: "단어 제안"
        }
    }
}
