import CryptoKit
import Foundation

/// Prepared values only: presentation never owns analysis, source scanning or navigation.
enum WritingDiagnosticsPresentation {
    enum Operation { case apply(Int), intentional, disableRule, learnWord(String) }
    struct Binding { let action: MarginAction; let operation: Operation }

    static func insights(from state: WritingDiagnosticsState) -> [MarginInsight] {
        state.findings.compactMap { finding in
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
    }
    static func bindings(for finding: WritingDiagnosticsFinding) -> [Binding] {
        var values: [Binding] = []
        func add(_ operation: Operation, verb: String, payload: String = "", kind: MarginAction.Kind = .custom, title: String) {
            let stamp = finding.stamp
            let components = [finding.id, stamp.runtime.key.projectID.rawValue.uuidString, stamp.runtime.key.documentID.rawValue.uuidString,
                String(stamp.runtime.generation), String(stamp.nativeRevision), String(stamp.profileRevision), stamp.providerRevision,
                String(stamp.ruleRevision), stamp.windowDigest, verb, payload]
            let bytes = try! JSONEncoder().encode(components)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
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
        case .vagueWord, .overusedWord, .wordAlternative: "단어 제안"
        }
    }
}
