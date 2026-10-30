import CryptoKit
import Foundation

/// Patterns describe original evidence in adjacent clauses; none is an automatic rewrite.
package enum KoreanRepetitionRules {
    private struct Scope: Hashable { let paragraph: Int; let dialogue: Int? }
    private struct Key: Hashable { let rule: String; let family: String; let scope: Scope }
    private struct Occurrence {
        let key: Key; let kind: WritingDiagnosticKind; let label: String
        let range: NSRange; let clause: Int
    }
    private static let auxiliaryWords: Set<String> = ["하", "되", "있", "없", "않"]

    package static func evaluate(_ analysis: KoreanAnalysis, profile: WritingStyleProfile) -> [WritingDiagnostic] {
        guard profile.repetitionSensitivity != .off else { return [] }
        let source = analysis.text as NSString
        let scopes = quoteScopes(in: source)
        let boundaries = clauseBoundaries(analysis, source: source)
        var groups: [Key: [Occurrence]] = [:], seen = Set<String>()
        func add(rule: String, family: String, kind: WritingDiagnosticKind, label: String,
                 range: NSRange, ownership: WritingDiagnosticRange) {
            guard range.length > 0, range.location >= 0, range.location < source.length,
                  range.length <= source.length - range.location,
                  source.rangeOfComposedCharacterSequences(for: range) == range else { return }
            let midpoint = range.location + range.length / 2
            guard midpoint >= ownership.location, midpoint < ownership.location + ownership.length else { return }
            let scope = scopes[midpoint]
            guard scope.dialogue == nil || profile.dialogueSensitivity != .off else { return }
            let id = "\(rule):\(family):\(range.location):\(range.length)"
            guard seen.insert(id).inserted else { return }
            let key = Key(rule: "ko.style.repeated-" + rule, family: family, scope: scope)
            let clause = boundaries.partitioningIndex { $0 > range.location }
            groups[key, default: []].append(.init(key: key, kind: kind, label: label, range: range, clause: clause))
        }
        for slice in analysis.slices {
            for (index, token) in slice.tokens.enumerated() where token.range.length > 0 {
                let tag = baseTag(token.tag), form = token.form.precomposedStringWithCanonicalMapping
                let range = token.range.nsRange
                if ["NNG", "NNP", "VV", "VA"].contains(tag), !auxiliaryWords.contains(form) {
                    add(rule: "word", family: tag + ":" + form, kind: .repeatedWord, label: "어휘", range: range, ownership: slice.ownership)
                }
                if let family = particle(form, tag: tag) {
                    add(rule: "particle", family: family, kind: .repeatedParticle, label: "조사", range: range, ownership: slice.ownership)
                }
                if tag == "EC" || tag == "EF", let family = ending(form, tag: tag) {
                    add(rule: "ending", family: family, kind: .repeatedEnding, label: "어미 계열", range: range, ownership: slice.ownership)
                }
                if tag == "MAJ" {
                    add(rule: "connector", family: form, kind: .repeatedConnector, label: "접속 표현", range: range, ownership: slice.ownership)
                }
                if let joined = compositeNde(at: index, tokens: slice.tokens, source: source) {
                    add(rule: "ending", family: "nde", kind: .repeatedEnding, label: "어미 계열", range: joined, ownership: slice.ownership)
                }
            }
        }
        var findings: [WritingDiagnostic] = []
        for (key, values) in groups where !profile.ignoredRuleIDs.contains(key.rule) {
            let sensitivity = key.scope.dialogue == nil ? profile.repetitionSensitivity : profile.dialogueSensitivity
            let required = threshold(sensitivity)
            let ordered = values.sorted { $0.range.location < $1.range.location }
            var run: [Occurrence] = []
            func finish() {
                guard run.count >= required, let last = run.last else { return }
                let surfaces = run.prefix(4).map { "‘" + source.substring(with: $0.range) + "’" }.joined(separator: ", ")
                let familyHash = SHA256.hash(data: Data(key.family.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
                findings.append(.init(id: "\(key.rule):\(last.range.location):\(familyHash)", ruleID: key.rule,
                    providerID: KoreanCorrectnessRules.providerID, category: .style, kind: last.kind, severity: .suggestion,
                    range: .init(last.range), relatedRanges: run.dropLast().map { .init($0.range) },
                    message: "같은 \(last.label) 표현이 가까이 반복됩니다.",
                    reason: "인접한 \(run.count)개 절·문장에서 \(surfaces) 표현을 반복했습니다. 의도한 리듬인지 확인해 보세요.",
                    languageTag: "ko"))
            }
            for occurrence in ordered {
                if let previous = run.last {
                    if occurrence.clause == previous.clause { continue }
                    if occurrence.clause != previous.clause + 1 { finish(); run.removeAll(keepingCapacity: true) }
                }
                run.append(occurrence)
            }
            finish()
        }
        return findings.sorted {
            $0.range.location == $1.range.location ? $0.id < $1.id : $0.range.location < $1.range.location
        }
    }

    private static func threshold(_ sensitivity: WritingQualitySensitivity) -> Int {
        switch sensitivity { case .off: Int.max; case .low: 4; case .standard: 3; case .high: 2 }
    }
    package static func baseTag(_ tag: String) -> String { String(tag.prefix { $0 != "-" }) }
    package static func particle(_ form: String, tag: String) -> String? {
        switch (tag, form) {
        case ("JX", "은"), ("JX", "는"): "topic"
        case ("JKS", "이"), ("JKS", "가"): "subject"
        case ("JKO", "을"), ("JKO", "를"): "object"
        case ("JX", "도"): "additive"
        case ("JX", "만"): "only"
        case ("JKB", _), ("JKG", _): tag + ":" + form
        default: nil
        }
    }
    package static func ending(_ form: String, tag: String) -> String? {
        if tag == "EF", ["다", "ᆫ다", "는다"].contains(form) { return nil }
        if tag == "EC", ["는데", "은데", "ᆫ데"].contains(form) { return "nde" }
        if tag == "EC", ["아서", "어서", "여서"].contains(form) { return "causal" }
        if tag == "EF", ["습니다", "ᆸ니다"].contains(form) { return "formal" }
        if tag == "EF", ["아요", "어요", "여요"].contains(form) { return "polite" }
        if tag == "EC", ["며", "으며"].contains(form) { return "and-while" }
        return tag + ":" + form
    }
    package static func compositeNde(at index: Int, tokens: [KoreanToken], source: NSString) -> NSRange? {
        guard index >= 1, index + 1 < tokens.count else { return nil }
        let modifier = tokens[index], noun = tokens[index + 1], predicate = tokens[index - 1]
        guard baseTag(modifier.tag) == "ETM", ["는", "은", "ᆫ"].contains(modifier.form),
              baseTag(noun.tag) == "NNB", noun.form == "데", ["VV", "VA", "VX"].contains(baseTag(predicate.tag)),
              modifier.range.length > 0, noun.range.length > 0,
              modifier.range.location + modifier.range.length == noun.range.location else { return nil }
        let range = NSUnionRange(modifier.range.nsRange, noun.range.nsRange)
        guard range.location >= 0, range.upperBound <= source.length else { return nil }
        return range
    }

    private static func clauseBoundaries(_ analysis: KoreanAnalysis, source: NSString) -> [Int] {
        var ends = Set<Int>()
        for slice in analysis.slices {
            func owns(_ range: NSRange) -> Bool {
                let middle = range.location + range.length / 2
                return range.length > 0 && middle >= slice.ownership.location
                    && middle < slice.ownership.location + slice.ownership.length
            }
            for (index, token) in slice.tokens.enumerated() {
                let tag = baseTag(token.tag)
                if owns(token.range.nsRange), ["EC", "EF", "SF"].contains(tag) {
                    ends.insert(token.range.location + token.range.length)
                }
                if let joined = compositeNde(at: index, tokens: slice.tokens, source: source), owns(joined) { ends.insert(joined.upperBound) }
            }
        }
        var result: [Int] = []
        for end in ends.sorted() {
            if let previous = result.last, end > previous {
                let gap = source.substring(with: NSRange(location: previous, length: end - previous))
                if gap.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0) }) {
                    result[result.count - 1] = end; continue
                }
            }
            result.append(end)
        }
        return result
    }

    private static func quoteScopes(in source: NSString) -> [Scope] {
        let pairs: [UInt16: UInt16] = [34: 34, 39: 39, 0x201C: 0x201D, 0x2018: 0x2019, 0x300C: 0x300D, 0x300E: 0x300F]
        var scopes: [Scope] = [], stack: [UInt16] = [], paragraph = 0, dialogue = -1, root: Int?
        var slashes = 0
        func asciiLetter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }
        for index in 0..<source.length {
            let unit = source.character(at: index)
            let apostrophe = unit == 39 && index > 0 && index + 1 < source.length
                && asciiLetter(source.character(at: index - 1)) && asciiLetter(source.character(at: index + 1))
            let escaped = slashes % 2 == 1
            var close = false
            if !escaped && !apostrophe {
                if stack.last == unit { close = true }
                else if let closing = pairs[unit] {
                    if stack.isEmpty { dialogue += 1; root = dialogue }
                    stack.append(closing)
                }
            }
            scopes.append(.init(paragraph: paragraph, dialogue: root))
            if close { stack.removeLast(); if stack.isEmpty { root = nil } }
            if unit == 10 || unit == 0x2029 || (unit == 13 && (index + 1 == source.length || source.character(at: index + 1) != 10)) { paragraph += 1 }
            slashes = unit == 92 ? slashes + 1 : 0
        }
        return scopes
    }
}

private extension Array where Element == Int {
    func partitioningIndex(_ predicate: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
