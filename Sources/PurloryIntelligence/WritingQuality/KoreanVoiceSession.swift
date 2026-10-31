import Foundation

/// One bounded fingerprint per declared speaker, private to an exact analysis request.
/// No learned profile or inference is persisted as an author decision.
package struct KoreanVoiceSession {
    private struct Candidate { let speaker: UUID; let range: NSRange; let evidence: NSRange }
    private struct Features {
        var endings: [String: Int] = [:]
        var vocabulary: [String: Int] = [:]
        mutating func add(_ token: KoreanToken) {
            let tag = KoreanRepetitionRules.baseTag(token.tag)
            let key = String(token.form.precomposedStringWithCanonicalMapping.prefix(32))
            if tag == "EF", endings.count < 32 || endings[key] != nil { endings[key, default: 0] += 1 }
            if ["NP", "MM", "MAG", "MAJ", "IC", "VV", "VA"].contains(tag), vocabulary.count < 64 || vocabulary[key] != nil {
                vocabulary[key, default: 0] += 1
            }
        }
    }
    private struct Sample { let range: NSRange; let features: Features }
    private let subjects: [UUID: String]
    private let candidates: [Candidate]
    private let profile: WritingStyleProfile
    private var cursor = 0
    private var pending = Features()
    private var histories: [UUID: [Sample]] = [:]
    private var sinceEmitted: [UUID: Int] = [:]
    package var retainedSampleCount: Int { histories.values.reduce(0) { $0 + $1.count } }

    package init(text: String, subjects: [WritingVoiceSubject], profile: WritingStyleProfile) throws {
        self.profile = profile
        guard profile.dialogueSensitivity != .off, !profile.ignoredRuleIDs.contains("ko.style.voice-shift"),
              !subjects.isEmpty, subjects.count <= 128, Set(subjects.map(\.id)).count == subjects.count else {
            self.subjects = [:]; candidates = []; return
        }
        self.subjects = Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, String($0.name.prefix(64))) })
        let cards = subjects.map { CharacterCard(id: $0.id, name: $0.name, aliases: $0.aliases.joined(separator: ",")) }
        candidates = try DialogueAttribution.explicitUtterances(in: text, cards: cards).map {
            let range = NSRange(location: $0.utf16Start, length: $0.text.utf16.count)
            let proof = $0.attributionRange.map { NSRange(location: $0.lowerBound, length: $0.count) } ?? range
            return Candidate(speaker: $0.speakerID, range: range, evidence: proof)
        }
    }

    package mutating func consume(_ analysis: KoreanAnalysis, proseOffset: Int) throws -> [WritingDiagnostic] {
        let owned = analysis.ownedRange?.nsRange ?? NSRange(location: 0, length: analysis.text.utf16.count)
        let end = proseOffset + owned.upperBound
        var output: [WritingDiagnostic] = []
        let tokens = analysis.tokens.filter { NSLocationInRange($0.range.location + $0.range.length / 2, owned) }
        while cursor < candidates.count, candidates[cursor].range.location < end {
            try Task.checkCancellation()
            let candidate = candidates[cursor]
            for token in tokens {
                let start = token.range.location + proseOffset, upper = start + token.range.length
                if token.range.length > 0, start >= candidate.range.location, upper <= candidate.range.upperBound { pending.add(token) }
            }
            guard candidate.evidence.upperBound <= end else { break }
            if !pending.endings.isEmpty, pending.vocabulary.values.reduce(0, +) >= 3 {
                var history = histories[candidate.speaker, default: []]
                history.append(.init(range: candidate.evidence, features: pending))
                sinceEmitted[candidate.speaker, default: 0] += 1
                let required = profile.dialogueSensitivity == .low ? 16 : 12
                if history.count > required { history.removeFirst(history.count - required) }
                histories[candidate.speaker] = history
                if history.count == required, sinceEmitted[candidate.speaker, default: 0] >= 4,
                   let finding = compare(history, speaker: candidate.speaker) {
                    output.append(finding); sinceEmitted[candidate.speaker] = 0
                }
            }
            pending = Features(); cursor += 1
        }
        return output
    }

    private func compare(_ samples: [Sample], speaker: UUID) -> WritingDiagnostic? {
        let recentCount = 4, split = samples.count - recentCount
        let baseline = samples.prefix(split), recent = samples.suffix(recentCount)
        func counts(_ samples: some Sequence<Sample>, _ path: KeyPath<Features, [String: Int]>) -> [String: Int] {
            samples.reduce(into: [:]) { result, sample in
                for (key, count) in sample.features[keyPath: path] { result[key, default: 0] += count }
            }
        }
        let earlierEndings = counts(baseline, \.endings), laterEndings = counts(recent, \.endings)
        let total = earlierEndings.values.reduce(0, +)
        guard total >= split, Double(earlierEndings.values.max() ?? 0) / Double(total) >= 0.75 else { return nil }
        let endings = Self.distance(earlierEndings, laterEndings)
        let vocabulary = Self.distance(counts(baseline, \.vocabulary), counts(recent, \.vocabulary))
        guard endings >= 0.65 || (endings >= 0.35 && vocabulary >= 0.75), let last = samples.last else { return nil }
        let rule = "ko.style.voice-shift"
        return .init(id: "\(rule):\(speaker):\(last.range.location)", ruleID: rule,
            providerID: KoreanCorrectnessRules.providerID, category: .style, kind: .characterVoice, severity: .suggestion,
            range: .init(last.range), relatedRanges: samples.dropLast().map { .init($0.range) },
            message: "\(subjects[speaker] ?? "인물")의 대사 말투가 앞부분과 달라졌습니다.",
            reason: "화자가 명시된 이전 \(split)개와 최근 \(recentCount)개 대사의 종결어미\(vocabulary >= 0.75 ? "·어휘" : "") 분포가 다릅니다. 장면에 따른 의도한 변화인지 원문을 확인해 보세요.",
            languageTag: "ko")
    }
    private static func distance(_ a: [String: Int], _ b: [String: Int]) -> Double {
        let totalA = Double(a.values.reduce(0, +)), totalB = Double(b.values.reduce(0, +))
        guard totalA > 0, totalB > 0 else { return 0 }
        return Set(a.keys).union(b.keys).sorted().reduce(0) {
            $0 + abs(Double(a[$1, default: 0]) / totalA - Double(b[$1, default: 0]) / totalB)
        } / 2
    }
}
