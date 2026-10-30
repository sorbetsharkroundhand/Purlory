import Foundation
import PurloryKoreanBackend

package struct KoreanToken: Hashable, Sendable {
    package let form: String
    package let tag: String
    package let range: WritingDiagnosticRange
}

package struct KoreanCorrectionCandidate: Sendable {
    package let originalRange: WritingDiagnosticRange
    package let replacement: String
    package let origin: String
}

package struct KoreanAnalysisSlice: Sendable {
    package let range: WritingDiagnosticRange
    package let ownership: WritingDiagnosticRange
    package let tokens: [KoreanToken]
    package let candidates: [KoreanCorrectionCandidate]
}

package struct KoreanAnalysis: Sendable {
    package let text: String
    package let tokens: [KoreanToken]
    package let sentences: [WritingDiagnosticRange]
    package let candidates: [KoreanCorrectionCandidate]
    package let slices: [KoreanAnalysisSlice]
    package let unsupportedRanges: [WritingDiagnosticRange]
    /// Exact nonoverlapping source ownership inside a contextual report window.
    package var ownedRange: WritingDiagnosticRange? = nil
}

package enum KoreanMorphologyError: Error { case invalidInput, invalidNativeOutput, unsupportedInput }

/// Native calls remain on the worker's utility thread, with bounded contextual admission.
package actor KoreanMorphology {
    private let worker: KoreanNativeWorker
    package init(worker: KoreanNativeWorker) { self.worker = worker }

    package func analyze(_ text: String) async throws -> KoreanAnalysis {
        try Task.checkCancellation()
        let ns = text as NSString
        guard ns.length <= 4096, !text.utf16.contains(0) else { throw KoreanMorphologyError.invalidInput }
        var tokens: [KoreanToken] = [], seen = Set<KoreanToken>(), sentences: [NSRange] = []
        var candidates: [KoreanCorrectionCandidate] = [], slices: [KoreanAnalysisSlice] = []
        var unsupported: [WritingDiagnosticRange] = []
        for core in WritingWindowSplitter.pieces(in: text, maximum: 768) {
            try Task.checkCancellation()
            guard core.length <= KoreanNativeWorker.maximumInputUTF16 else { unsupported.append(core); continue }
            var start = core.location, end = core.location + core.length
            if core.length <= 768 {
                start = max(0, start - 128); end = min(ns.length, end + 128)
                if start > 0 {
                    let cluster = ns.rangeOfComposedCharacterSequence(at: start)
                    if cluster.location < start { start = cluster.upperBound }
                }
                if end < ns.length {
                    let cluster = ns.rangeOfComposedCharacterSequence(at: end)
                    if cluster.location < end { end = cluster.location }
                }
            }
            let context = NSRange(location: start, length: end - start)
            guard context.length <= KoreanNativeWorker.maximumInputUTF16 else { throw KoreanMorphologyError.invalidInput }
            let input = KoreanNormalizedInput(ns.substring(with: context))
            guard input.lookup.utf16.count <= KoreanNativeWorker.maximumInputUTF16 else { unsupported.append(core); continue }
            let native = try await worker.analyze(input.lookup)
            try Task.checkCancellation()
            let converted = try Self.convert(native, text: input.lookup, offset: start, normalization: input)
            for token in converted.tokens {
                let middle = token.range.location + token.range.length / 2
                if (middle >= core.location && middle < core.location + core.length
                    || middle == ns.length && core.location + core.length == ns.length), seen.insert(token).inserted {
                    tokens.append(token)
                }
            }
            sentences += converted.sentences.map(\.nsRange)
            candidates += converted.candidates
            slices.append(.init(range: .init(context), ownership: core, tokens: converted.tokens, candidates: converted.candidates))
            await Task.yield()
        }
        var merged: [NSRange] = []
        for sentence in sentences.sorted(by: { $0.location < $1.location }) {
            if let previous = merged.last, NSIntersectionRange(previous, sentence).length > 0 {
                merged[merged.count - 1] = NSUnionRange(previous, sentence)
            } else { merged.append(sentence) }
        }
        return KoreanAnalysis(text: text, tokens: tokens, sentences: merged.map(WritingDiagnosticRange.init),
                              candidates: candidates, slices: slices, unsupportedRanges: unsupported)
    }

    /// Validate before the public range initializer can clamp a malformed native offset.
    package static func convert(_ native: KoreanNativeAnalysis, text: String, offset: Int = 0, normalization: KoreanNormalizedInput? = nil) throws
        -> (tokens: [KoreanToken], sentences: [WritingDiagnosticRange], candidates: [KoreanCorrectionCandidate]) {
        let length = text.utf16.count
        let units = text as NSString
        guard offset >= 0, offset <= 4096, (normalization?.sourceLength ?? length) <= 4096 - offset else {
            throw KoreanMorphologyError.invalidNativeOutput
        }
        func mapped(_ range: NSRange) throws -> WritingDiagnosticRange {
            func scalarBoundary(_ position: Int) -> Bool {
                guard position > 0 && position < length else { return true }
                return !(0xDC00...0xDFFF).contains(units.character(at: position))
                    || !(0xD800...0xDBFF).contains(units.character(at: position - 1))
            }
            guard range.location >= 0, range.location <= length, range.length >= 0,
                  range.length <= length - range.location, Range(range, in: text) != nil,
                  scalarBoundary(range.location), scalarBoundary(range.upperBound),
                  offset >= 0, offset <= Int.max - range.location else { throw KoreanMorphologyError.invalidNativeOutput }
            let original: NSRange
            if let normalization {
                guard let proved = normalization.originalRange(for: range) else { throw KoreanMorphologyError.invalidNativeOutput }
                original = proved
            } else { original = range }
            return .init(location: offset + original.location, length: original.length)
        }
        let tokens = try native.tokens.map { KoreanToken(form: $0.form, tag: $0.tag, range: try mapped($0.range)) }
        let sentences = try native.sentences.map(mapped).filter { $0.length > 0 }
        let candidates = try native.candidates.map {
            guard $0.replacement.utf16.count <= 4096, !$0.replacement.utf16.contains(0) else { throw KoreanMorphologyError.invalidNativeOutput }
            return KoreanCorrectionCandidate(originalRange: try mapped($0.originalRange), replacement: $0.replacement, origin: $0.origin)
        }
        return (tokens, sentences, candidates)
    }
}

/// NFC is a lookup view only; exact original offsets remain the manuscript authority.
package struct KoreanNormalizedInput: Sendable {
    private struct Part: Sendable { let source: NSRange; let lookup: NSRange; let linear: Bool }
    package let lookup: String
    package let sourceLength: Int
    private let parts: [Part]

    package init(_ source: String) {
        var lookup = "", sourceOffset = 0, lookupOffset = 0, parts: [Part] = []
        for character in source {
            let original = String(character), normalized = original.precomposedStringWithCanonicalMapping
            let a = original.utf16.count, b = normalized.utf16.count
            parts.append(.init(source: NSRange(location: sourceOffset, length: a), lookup: NSRange(location: lookupOffset, length: b),
                               linear: original.utf16.elementsEqual(normalized.utf16)))
            lookup += normalized; sourceOffset += a; lookupOffset += b
        }
        self.lookup = lookup; sourceLength = sourceOffset; self.parts = parts
    }

    package func originalRange(for range: NSRange) -> NSRange? {
        let length = lookup.utf16.count
        guard range.location >= 0, range.location <= length, range.length >= 0, range.length <= length - range.location else { return nil }
        if range.length == 0 && range.location == length { return NSRange(location: sourceLength, length: 0) }
        guard let first = parts.first(where: { NSLocationInRange(range.location, $0.lookup) }) else { return nil }
        let start: Int
        if first.linear { start = first.source.location + range.location - first.lookup.location }
        else if range.location == first.lookup.location { start = first.source.location }
        else { return nil }
        if range.length == 0 { return NSRange(location: start, length: 0) }
        guard let last = parts.first(where: { NSLocationInRange(range.upperBound - 1, $0.lookup) }) else { return nil }
        let end: Int
        if last.linear { end = last.source.location + range.upperBound - last.lookup.location }
        else if range.upperBound == last.lookup.upperBound { end = last.source.upperBound }
        else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
