import Foundation

/// Reviewed morphological signatures promote native alternatives; joining alone is not proof.
package enum KoreanCorrectnessRules {
    package static let revision = 1
    package static let providerID = "ko.kiwi.v0.24.0"
    private struct Edit { let range: NSRange; let replacement: String }
    private static let words = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+"#)

    package static func evaluate(_ analysis: KoreanAnalysis, profile: WritingStyleProfile) -> [WritingDiagnostic] {
        let source = analysis.text as NSString
        let lexicalWords = words.matches(in: analysis.text, range: NSRange(location: 0, length: source.length))
        var findings: [WritingDiagnostic] = [], seen = Set<String>()
        func learned(_ range: NSRange) -> Bool {
            profile.learnedWords.contains(source.substring(with: range).precomposedStringWithCanonicalMapping)
        }
        func emit(_ range: NSRange, lexical: NSRange, alternative: String, slice: KoreanAnalysisSlice,
                  rule: String, kind: WritingDiagnosticKind, message: String, reason: String) {
            let midpoint = range.location + range.length / 2
            guard midpoint >= slice.ownership.location, midpoint < slice.ownership.location + slice.ownership.length,
                  range.length > 0, range.location >= 0, range.upperBound <= source.length,
                  source.rangeOfComposedCharacterSequences(for: range) == range,
                  !profile.ignoredRuleIDs.contains(rule), !learned(lexical), !quotedLiteral(lexical, in: source) else { return }
            let id = "\(rule):\(range.location):\(range.length)"
            guard seen.insert(id).inserted else { return }
            findings.append(.init(id: id, ruleID: rule, providerID: providerID, category: .correctness,
                kind: kind, severity: .correctness, range: .init(range), message: message, reason: reason,
                alternatives: [alternative], languageTag: "ko"))
        }
        for slice in analysis.slices {
            for candidate in slice.candidates where candidate.origin == "kiwi.join" && candidate.originalRange == slice.range {
                let input = source.substring(with: slice.range.nsRange)
                guard let edits = changes(from: input, to: candidate.replacement, offset: slice.range.location) else { continue }
                for word in lexicalWords where word.range.location >= slice.range.location && word.range.upperBound <= slice.range.location + slice.range.length {
                    guard source.substring(with: word.range).precomposedStringWithCanonicalMapping == "됬다" else { continue }
                    let tokens = slice.tokens.filter { overlaps($0.range.nsRange, word.range) }
                    let forms = tokens.map { ($0.form, baseTag($0.tag)) }
                    guard forms.count == 3, forms[0].0 == "되", forms[0].1 == "VV",
                          forms[1].0 == "었", forms[1].1 == "EP", forms[2].0 == "다", forms[2].1 == "EF",
                          let alternative = alternative(for: word.range, source: source, edits: edits),
                          alternative.utf16.elementsEqual("됐다".utf16) else { continue }
                    emit(word.range, lexical: word.range, alternative: alternative, slice: slice, rule: "ko.correctness.doeda-past", kind: .spelling,
                         message: "‘됬다’를 ‘됐다’로 고칠 수 있습니다.", reason: "분석된 ‘되다’의 과거형은 ‘됐다’로 적습니다.")
                }
                for (index, noun) in slice.tokens.enumerated() where noun.form == "수" && baseTag(noun.tag) == "NNB" && noun.range.length > 0 {
                    guard index >= 2, index + 2 < slice.tokens.count else { continue }
                    let stem = slice.tokens[index - 2], modifier = slice.tokens[index - 1]
                    let predicate = slice.tokens[index + 1], ending = slice.tokens[index + 2]
                    guard ["VV", "VA"].contains(baseTag(stem.tag)), baseTag(modifier.tag) == "ETM",
                          ["ᆯ", "을"].contains(modifier.form), ["있", "없"].contains(predicate.form), ["VA", "VX"].contains(baseTag(predicate.tag)),
                          ending.form == "다", baseTag(ending.tag) == "EF",
                          stem.range.length > 0, ending.range.length > 0, ending.range.location >= stem.range.location,
                          let head = lexicalWords.first(where: { $0.range.location == stem.range.location }),
                          head.range.upperBound >= stem.range.location + stem.range.length else { continue }
                    let bounds = NSRange(location: stem.range.location, length: ending.range.location + ending.range.length - stem.range.location)
                    guard bounds.location >= slice.range.location, bounds.upperBound <= slice.range.location + slice.range.length,
                          noun.range.location > stem.range.location, predicate.range.location >= noun.range.location + noun.range.length,
                          source.substring(with: noun.range.nsRange).precomposedStringWithCanonicalMapping == "수" else { continue }
                    let gap = NSRange(location: noun.range.location + noun.range.length,
                                      length: predicate.range.location - noun.range.location - noun.range.length)
                    guard source.substring(with: gap).allSatisfy({ $0 == " " || $0 == "\t" }),
                          !source.substring(with: bounds).contains(where: { $0 == "\n" || $0 == "\r" }) else { continue }
                    var insertions: [Int] = []
                    let previous = source.character(at: noun.range.location - 1)
                    if previous != 32 && previous != 9 { insertions.append(noun.range.location) }
                    if gap.length == 0 { insertions.append(predicate.range.location) }
                    guard let first = insertions.first, let lexical = lexicalWords.first(where: {
                        $0.range.location < first && first < $0.range.upperBound
                    }), insertions.allSatisfy({ $0 > lexical.range.location && $0 < lexical.range.upperBound }) else { continue }
                    var expected = source.substring(with: bounds)
                    for position in insertions.reversed() {
                        expected = (expected as NSString).replacingCharacters(in: NSRange(location: position - bounds.location, length: 0), with: " ")
                    }
                    expected = expected.precomposedStringWithCanonicalMapping
                    guard
                          let alternative = alternative(for: bounds, source: source, edits: edits),
                          alternative.utf16.elementsEqual(expected.utf16) else { continue }
                    emit(bounds, lexical: lexical.range, alternative: alternative, slice: slice, rule: "ko.correctness.bound-noun-su", kind: .spacing,
                         message: "의존 명사 ‘수’의 띄어쓰기를 확인해 보세요.", reason: "가능성·능력을 나타내는 의존 명사 ‘수’는 앞말 및 뒤의 서술어와 띄어 씁니다.")
                }
            }
        }
        return findings.sorted { $0.range.location < $1.range.location }
    }

    private static func baseTag(_ tag: String) -> String { String(tag.prefix { $0 != "-" }) }
    private static func quotedLiteral(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location > 0, range.upperBound < source.length else { return false }
        let pairs: [UInt16: UInt16] = [34: 34, 39: 39, 0x201C: 0x201D, 0x2018: 0x2019, 0x300C: 0x300D, 0x300E: 0x300F]
        return pairs[source.character(at: range.location - 1)] == source.character(at: range.upperBound)
    }
    private static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        a.length > 0 ? NSIntersectionRange(a, b).length > 0 : a.location >= b.location && a.location < b.upperBound
    }
    private static func alternative(for range: NSRange, source: NSString, edits: [Edit]) -> String? {
        var relevant: [Edit] = []
        for edit in edits {
            let touches = edit.range.length > 0 ? NSIntersectionRange(edit.range, range).length > 0
                : edit.range.location >= range.location && edit.range.location < range.upperBound
            guard touches else { continue }
            guard edit.range.location >= range.location, edit.range.upperBound <= range.upperBound else { return nil }
            relevant.append(edit)
        }
        guard !relevant.isEmpty else { return nil }
        var result = source.substring(with: range)
        for edit in relevant.reversed() {
            result = (result as NSString).replacingCharacters(in: NSRange(location: edit.range.location - range.location, length: edit.range.length), with: edit.replacement)
        }
        return result
    }

    /// Diff only one admitted native input. Preserve original UTF-16, including NFD/emoji.
    private static func changes(from source: String, to joined: String, offset: Int) -> [Edit]? {
        let before = Array(source.utf16), after = Array(joined.utf16)
        guard before.count <= 1024, after.count <= 4096 else { return nil }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case let .remove(index, _, _): removed.insert(index)
            case let .insert(index, _, _): inserted.insert(index)
            }
        }
        var old = 0, new = 0, edits: [Edit] = []
        while old < before.count || new < after.count {
            if removed.contains(old) || inserted.contains(new) {
                let start = old
                var replacement: [UInt16] = []
                while removed.contains(old) || inserted.contains(new) {
                    if removed.contains(old) { old += 1 }
                    if inserted.contains(new) { replacement.append(after[new]); new += 1 }
                }
                let text = String(decoding: replacement, as: UTF16.self)
                guard text.utf16.elementsEqual(replacement) else { return nil }
                edits.append(.init(range: NSRange(location: offset + start, length: old - start), replacement: text))
            } else {
                guard old < before.count, new < after.count, before[old] == after[new] else { return nil }
                old += 1; new += 1
            }
        }
        return edits
    }
}
