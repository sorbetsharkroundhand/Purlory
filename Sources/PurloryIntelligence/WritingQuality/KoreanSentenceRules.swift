import CryptoKit
import Foundation

package struct KoreanDiagnosticsChunk: Sendable {
    package let diagnostics: [WritingDiagnostic]
    package let assessedRange: WritingDiagnosticRange
    package let totalProseUTF16: Int
    package let unsupportedRanges: [WritingDiagnosticRange]
}

/// Private to one exact request; no project, text buffer, native handle or shared mutable state.
package struct KoreanRuleSession {
    private struct Family: Hashable { let rule: String; let key: String; let kind: WritingDiagnosticKind; let label: String }
    private struct Evidence { let range: NSRange; let label: String }
    private struct Run {
        var count = 0
        var evidence: [Evidence] = []
        mutating func add(_ item: Evidence, limit: Int) {
            count += 1
            if evidence.count < limit { evidence.append(item) }
            else { evidence.removeFirst(); evidence.append(item) }
        }
    }
    private struct SentencePattern {
        let key: String
        var run: Run
    }
    private let profile: WritingStyleProfile
    private var cursor = 0
    private var quotes: [UInt16] = []
    private var quoteOverflow = 0
    private var slashCount = 0
    private var previousUnit: UInt16?
    private var sentenceStart: Int?
    private var sentenceEnd = 0
    private var terminalEnd: Int?
    private var clauseEnd: Int?
    private var hasClause = false
    private var clauseCount = 0
    private var endings = SHA256()
    private var starts: [Evidence] = []
    private var startForms: [String] = []
    private var causal: Evidence?
    private var current: [Family: Evidence] = [:]
    private var runs: [Family: Run] = [:]
    private var startRun: SentencePattern?
    private var rhythmRun: SentencePattern?
    private var output: [WritingDiagnostic] = []
    package private(set) var acceptsInput = true
    package private(set) var unsupportedRanges: [WritingDiagnosticRange] = []
    private var clauseUnsupported = false
    package static let maximumFamilies = 1024
    package static let maximumQuoteDepth = 32
    package var retainedOccurrenceCount: Int {
        var count = current.count + starts.count
        for run in runs.values { count += run.evidence.count }
        count += startRun?.run.evidence.count ?? 0
        count += rhythmRun?.run.evidence.count ?? 0
        return count
    }
    package var retainedQuoteDepth: Int { quotes.count }
    package var retainedTextUTF16: Int {
        func size(_ values: [Evidence]) -> Int { values.reduce(0) { $0 + $1.label.utf16.count } }
        var count = size(starts)
        for value in current.values { count += value.label.utf16.count }
        for run in runs.values { count += size(run.evidence) }
        count += size(startRun?.run.evidence ?? [])
        count += size(rhythmRun?.run.evidence ?? [])
        count += causal?.label.utf16.count ?? 0
        return count
    }

    package init(profile: WritingStyleProfile) { self.profile = profile }
    package mutating func reset() { self = KoreanRuleSession(profile: profile) }

    package mutating func consume(_ analysis: KoreanAnalysis, proseOffset: Int, final: Bool) -> [WritingDiagnostic] {
        output.removeAll(keepingCapacity: true); unsupportedRanges.removeAll(keepingCapacity: true)
        let ns = analysis.text as NSString
        let owned = analysis.ownedRange?.nsRange ?? NSRange(location: 0, length: ns.length)
        guard proseOffset >= 0, owned.location >= 0, owned.length >= 0, owned.location <= ns.length,
              owned.length <= ns.length - owned.location, proseOffset <= Int.max - owned.upperBound,
              proseOffset + owned.location == cursor,
              sourceOwnsWholeGraphemes(owned, in: ns) else {
            reset(); acceptsInput = false; return []
        }
        let global = NSRange(location: proseOffset + owned.location, length: owned.length)
        for finding in KoreanCorrectnessRules.evaluate(analysis, profile: profile) {
            let middle = finding.range.location + finding.range.length / 2
            if NSLocationInRange(middle, owned) { output.append(shift(finding, by: proseOffset)) }
        }
        if profile.repetitionSensitivity == .off { cursor = global.upperBound; return output }
        let tokens = KoreanSentenceRules.tokens(in: analysis).filter { _, token in
            let middle = token.range.location + token.range.length / 2
            return token.range.length > 0 && NSLocationInRange(middle, owned)
        }.sorted {
            let a = $0.element.range.location + $0.element.range.length / 2, b = $1.element.range.location + $1.element.range.length / 2
            return a == b ? $0.offset < $1.offset : a < b
        }
        var scan = owned.location
        for (index, token) in tokens {
            let point = token.range.location + token.range.length / 2
            scanText(ns, from: &scan, to: min(point, owned.upperBound), offset: proseOffset)
            receive(token, index: index, analysis: analysis, source: ns, offset: proseOffset)
        }
        scanText(ns, from: &scan, to: owned.upperBound, offset: proseOffset)
        cursor = global.upperBound
        unsupportedRanges += analysis.unsupportedRanges.map { .init(location: proseOffset + $0.location, length: $0.length) }
        if final { finishSentence(); finishRuns(); finishPatterns() }
        let result = output.sorted { $0.range.location == $1.range.location ? $0.id < $1.id : $0.range.location < $1.range.location }
        output.removeAll(keepingCapacity: true)
        return result
    }

    private func sourceOwnsWholeGraphemes(_ range: NSRange, in source: NSString) -> Bool {
        if range.length == 0 { return range.location == source.length || source.rangeOfComposedCharacterSequence(at: range.location).location == range.location }
        return source.rangeOfComposedCharacterSequences(for: range) == range
    }

    private var sensitivity: WritingQualitySensitivity { quotes.isEmpty ? profile.repetitionSensitivity : profile.dialogueSensitivity }
    private var styleEnabled: Bool { profile.repetitionSensitivity != .off && sensitivity != .off && quoteOverflow == 0 }
    private var threshold: Int { switch sensitivity { case .off: Int.max; case .low: 4; case .standard: 3; case .high: 2 } }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
    private func shift(_ finding: WritingDiagnostic, by offset: Int) -> WritingDiagnostic {
        var result = finding
        result.range.location += offset
        result.relatedRanges = result.relatedRanges.map { .init(location: $0.location + offset, length: $0.length) }
        result.id = "\(result.ruleID):\(result.range.location):\(result.range.length)"
        return result
    }

    private mutating func scanText(_ source: NSString, from scan: inout Int, to end: Int, offset: Int) {
        let pairs: [UInt16: UInt16] = [34: 34, 39: 39, 0x201C: 0x201D, 0x2018: 0x2019, 0x300C: 0x300D, 0x300E: 0x300F]
        func asciiLetter(_ unit: UInt16?) -> Bool { guard let unit else { return false }; return (65...90).contains(unit) || (97...122).contains(unit) }
        while scan < end {
            let unit = source.character(at: scan), position = offset + scan
            let next: UInt16? = scan + 1 < source.length ? source.character(at: scan + 1) : nil
            let apostrophe = unit == 39 && asciiLetter(previousUnit) && asciiLetter(next)
            let scalar = UnicodeScalar(unit)
            let whitespace = scalar.map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            let punctuation = scalar.map { CharacterSet.punctuationCharacters.contains($0) } ?? false
            let escaped = slashCount % 2 == 1
            var delimiter = false
            if !escaped && !apostrophe && quoteOverflow == 0 {
                if quotes.last == unit {
                    delimiter = true
                    if quotes.count == 1 { finishSentence(); finishRuns(); finishPatterns() }
                    quotes.removeLast()
                } else if let closing = pairs[unit] {
                    delimiter = true
                    if quotes.isEmpty { finishSentence(); finishRuns(); finishPatterns() }
                    if quotes.count < Self.maximumQuoteDepth { quotes.append(closing) }
                    else {
                        quoteOverflow = 1
                        current.removeAll(keepingCapacity: true); runs.removeAll(keepingCapacity: true)
                        startRun = nil; rhythmRun = nil
                    }
                }
            }
            if quoteOverflow > 0 { markUnsupported(NSRange(location: position, length: 1)) }
            if unit == 10 || unit == 0x2029 || (unit == 13 && next != 10) {
                finishSentence(); finishRuns(); finishPatterns()
            } else if !delimiter && !whitespace {
                if let terminalEnd, position >= terminalEnd, !punctuation { finishSentence() }
                if sentenceStart == nil { sentenceStart = position }
                sentenceEnd = position + 1
            }
            slashCount = unit == 92 ? slashCount + 1 : 0
            previousUnit = unit; scan += 1
        }
    }

    private mutating func receive(_ token: KoreanToken, index: Int, analysis: KoreanAnalysis, source: NSString, offset: Int) {
        let tag = KoreanRepetitionRules.baseTag(token.tag), form = token.form.precomposedStringWithCanonicalMapping
        let raw = token.range.nsRange
        guard raw.location >= 0, raw.length > 0, raw.upperBound <= source.length,
              source.rangeOfComposedCharacterSequences(for: raw) == raw else { return }
        let range = NSRange(location: offset + raw.location, length: raw.length)
        if let terminalEnd, range.location >= terminalEnd, !["SF", "SP", "SS", "SSO", "SSC"].contains(tag) { finishSentence() }
        if let clauseEnd, range.location >= clauseEnd, !["SF", "SP", "SS", "SSO", "SSC"].contains(tag) { finishClause(); self.clauseEnd = nil }
        let lexical = ["NNG", "NNP", "NNB", "NP", "NR", "MM", "VV", "VA", "VX", "SL", "SN"].contains(tag)
        if lexical {
            hasClause = true
            if starts.count < 2 { starts.append(.init(range: range, label: String(form.prefix(32)))); startForms.append(hash(form)) }
        }
        if styleEnabled {
            if tag == "MAJ", form == "그래서", !KoreanSentenceRules.isQuotedLiteral(raw, in: source), let causal {
                emit("redundant-causality", kind: .redundantConnector, range: range, related: [causal.range],
                     message: "인과 표현이 한 연결부에 겹칩니다.", reason: "‘\(causal.label)’ 뒤에 ‘그래서’가 이어집니다. 두 인과 표현을 모두 쓸지 확인해 보세요.")
            }
            if ["NNG", "NNP", "VV", "VA"].contains(tag), !["하", "되", "있", "없", "않"].contains(form) {
                add(.init(rule: "repeated-word", key: tag + ":" + hash(form), kind: .repeatedWord, label: "어휘"), range: range, label: source.substring(with: raw))
            }
            if let family = KoreanRepetitionRules.particle(form, tag: tag) { add(.init(rule: "repeated-particle", key: family, kind: .repeatedParticle, label: "조사"), range: range, label: source.substring(with: raw)) }
            if tag == "EC" || tag == "EF", let family = KoreanRepetitionRules.ending(form, tag: tag) { add(.init(rule: "repeated-ending", key: family, kind: .repeatedEnding, label: "어미 계열"), range: range, label: source.substring(with: raw)) }
            if tag == "MAJ", !KoreanSentenceRules.isQuotedLiteral(raw, in: source) { add(.init(rule: "repeated-connector", key: form, kind: .repeatedConnector, label: "접속 표현"), range: range, label: source.substring(with: raw)) }
        }
        if !["SP", "SS", "SSO", "SSC"].contains(tag) { causal = nil }
        if tag == "EC", KoreanRepetitionRules.ending(form, tag: tag) == "causal" { causal = .init(range: range, label: source.substring(with: raw)) }
        if tag == "EC" || tag == "EF" {
            let family = KoreanRepetitionRules.ending(form, tag: tag) ?? (tag + ":" + form)
            endings.update(data: Data((family + "\u{0}").utf8))
            if tag == "EC" { clauseEnd = range.upperBound } else { terminalEnd = range.upperBound }
        } else if tag == "SF" { terminalEnd = range.upperBound }
        // Kiwi can classify inflected -는데 as ETM + the bound noun 데.
        if let joined = KoreanRepetitionRules.compositeNde(at: index, tokens: analysis.tokens, source: source) {
            let composed = NSRange(location: offset + joined.location, length: joined.length)
            if styleEnabled { add(.init(rule: "repeated-ending", key: "nde", kind: .repeatedEnding, label: "어미 계열"), range: composed, label: source.substring(with: joined)) }
            endings.update(data: Data("nde\u{0}".utf8)); clauseEnd = composed.upperBound
        }
    }

    private mutating func add(_ key: Family, range: NSRange, label: String) {
        guard current[key] == nil else { return }
        guard current.count < Self.maximumFamilies else { clauseUnsupported = true; return }
        current[key] = Evidence(range: range, label: String(label.prefix(32)))
    }
    private mutating func finishClause() {
        guard hasClause || !current.isEmpty else { return }
        for key in Array(runs.keys) where current[key] == nil { finishRun(key) }
        for (key, value) in current {
            var run = runs[key] ?? Run(); run.add(value, limit: min(4, threshold)); runs[key] = run
        }
        current.removeAll(keepingCapacity: true); hasClause = false; clauseCount += 1
        if clauseUnsupported, let sentenceStart { markUnsupported(NSRange(location: sentenceStart, length: max(1, sentenceEnd - sentenceStart))) }
    }
    private mutating func finishRun(_ key: Family) {
        guard let run = runs.removeValue(forKey: key), run.count >= threshold, let last = run.evidence.last else { return }
        let examples = run.evidence.map { "‘" + $0.label + "’" }.joined(separator: ", ")
        emit(key.rule, kind: key.kind, range: last.range, related: run.evidence.dropLast().map(\.range), suffix: hash(key.key),
             message: "같은 \(key.label) 표현이 가까이 반복됩니다.", reason: "인접한 \(run.count)개 절·문장에서 \(examples) 표현을 반복했습니다. 의도한 리듬인지 확인해 보세요.")
    }
    private mutating func finishRuns() { finishClause(); for key in Array(runs.keys) { finishRun(key) } }
    private mutating func finishSentence() {
        guard let start = sentenceStart else { return }
        finishClause()
        let range = NSRange(location: start, length: max(0, sentenceEnd - start))
        if styleEnabled, range.length > 0, !clauseUnsupported {
            if clauseCount >= 4 { emit("connective-chain", kind: .connectiveChain, range: range, message: "한 문장에 여러 절이 이어집니다.", reason: "이 문장은 \(clauseCount)개 절을 연결합니다. 호흡을 나눌 위치를 확인해 보세요.") }
            if range.length > 120 { emit("sentence-length", kind: .sentenceLength, severity: .info, range: range, message: "긴 문장입니다.", reason: "이 문장은 UTF-16 기준 \(range.length)자로 120자를 넘습니다. 의도한 호흡인지 확인해 보세요.") }
            var nextStart = startRun, nextRhythm = rhythmRun
            if starts.count == 2 {
                let first = Evidence(range: NSUnionRange(starts[0].range, starts[1].range), label: starts.map(\.label).joined(separator: " "))
                updatePattern(&nextStart, key: hash(startForms.joined(separator: "\u{0}")), evidence: first, rule: "repeated-sentence-start", kind: .repeatedSentenceStart, limit: min(4, threshold))
            } else { closePattern(&nextStart, rule: "repeated-sentence-start", kind: .repeatedSentenceStart) }
            let digest = endings.finalize().map { String(format: "%02x", $0) }.joined()
            updatePattern(&nextRhythm, key: "\(clauseCount):\(digest)", evidence: .init(range: range, label: "\(clauseCount)개 절"), rule: "sentence-rhythm", kind: .sentenceRhythm, limit: 3)
            startRun = nextStart; rhythmRun = nextRhythm
        } else { finishPatterns() }
        sentenceStart = nil; sentenceEnd = 0; terminalEnd = nil; clauseEnd = nil
        hasClause = false; clauseCount = 0; endings = SHA256(); starts.removeAll(keepingCapacity: true); startForms.removeAll(keepingCapacity: true)
        causal = nil; clauseUnsupported = false
    }
    // Work with local copies to avoid overlapping mutating access to session storage.
    private mutating func updatePattern(_ pattern: inout SentencePattern?, key: String, evidence: Evidence, rule: String, kind: WritingDiagnosticKind, limit: Int) {
        if pattern?.key != key { closePattern(&pattern, rule: rule, kind: kind); pattern = .init(key: key, run: Run()) }
        pattern?.run.add(evidence, limit: limit)
    }
    private mutating func closePattern(_ pattern: inout SentencePattern?, rule: String, kind: WritingDiagnosticKind) {
        defer { pattern = nil }
        let required = kind == .sentenceRhythm ? 3 : threshold
        guard let pattern, pattern.run.count >= required, let last = pattern.run.evidence.last else { return }
        let rhythm = kind == .sentenceRhythm
        emit(rule, kind: kind, severity: rhythm ? .info : .suggestion, range: last.range, related: pattern.run.evidence.dropLast().map(\.range), suffix: hash(pattern.key),
             message: rhythm ? "문장 호흡이 연속해서 같습니다." : "문장 시작이 연속해서 같습니다.",
             reason: rhythm ? "인접한 \(pattern.run.count)개 문장의 절 수와 어미 계열 순서가 같습니다. 의도한 리듬인지 확인해 보세요." : "인접한 \(pattern.run.count)개 문장이 ‘\(last.label)’의 두 어휘로 시작합니다. 의도한 반복인지 확인해 보세요.")
    }
    private mutating func finishPatterns() {
        var first = startRun, rhythm = rhythmRun
        closePattern(&first, rule: "repeated-sentence-start", kind: .repeatedSentenceStart)
        closePattern(&rhythm, rule: "sentence-rhythm", kind: .sentenceRhythm)
        startRun = first; rhythmRun = rhythm
    }
    private mutating func markUnsupported(_ range: NSRange) {
        if let last = unsupportedRanges.last, last.nsRange.upperBound >= range.location, range.upperBound >= last.location {
            unsupportedRanges[unsupportedRanges.count - 1] = .init(NSUnionRange(last.nsRange, range))
        } else { unsupportedRanges.append(.init(range)) }
    }
    private mutating func emit(_ rule: String, kind: WritingDiagnosticKind, severity: WritingDiagnosticSeverity = .suggestion, range: NSRange, related: [NSRange] = [], suffix: String = "", message: String, reason: String) {
        let id = "ko.style." + rule
        guard !profile.ignoredRuleIDs.contains(id), range.length > 0 else { return }
        output.append(.init(id: "\(id):\(range.location):\(range.length):\(suffix)", ruleID: id, providerID: KoreanCorrectnessRules.providerID,
                            category: .style, kind: kind, severity: severity, range: .init(range), relatedRanges: related.map(WritingDiagnosticRange.init),
                            message: message, reason: reason, languageTag: "ko"))
    }
}

/// Morphological alternatives for a connector are folded only with exact source evidence.
package enum KoreanSentenceRules {
    package static func isQuotedLiteral(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location > 0, range.upperBound < source.length else { return false }
        let pairs: [UInt16: UInt16] = [34: 34, 39: 39, 0x201C: 0x201D, 0x2018: 0x2019, 0x300C: 0x300D, 0x300E: 0x300F]
        return pairs[source.character(at: range.location - 1)] == source.character(at: range.upperBound)
    }

    package static func tokens(in analysis: KoreanAnalysis) -> [(offset: Int, element: KoreanToken)] {
        let source = analysis.text as NSString
        var result: [(Int, KoreanToken)] = [], index = 0
        while index < analysis.tokens.count {
            let token = analysis.tokens[index]
            if index + 1 < analysis.tokens.count {
                let next = analysis.tokens[index + 1]
                let tag = KoreanRepetitionRules.baseTag(token.tag)
                let range = NSUnionRange(token.range.nsRange, next.range.nsRange)
                if ["VV", "VA"].contains(tag), ["그러", "그렇"].contains(token.form),
                   KoreanRepetitionRules.baseTag(next.tag) == "EC", next.form == "어서",
                   token.range.length > 0, next.range.length > 0,
                   range.location >= 0, range.upperBound <= source.length,
                   source.substring(with: range).precomposedStringWithCanonicalMapping == "그래서" {
                    result.append((index, .init(form: "그래서", tag: "MAJ", range: .init(range))))
                    index += 2; continue
                }
            }
            result.append((index, token)); index += 1
        }
        return result
    }
}
