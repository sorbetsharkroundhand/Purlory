import Foundation
import PurloryKoreanBackend

package actor KoreanDiagnosticsProvider: WritingDiagnosticsProvider, WritingDiagnosticsFailureClassifying {
    package nonisolated let id = KoreanCorrectnessRules.providerID
    package nonisolated static let ruleRevision = 3
    private let morphology: KoreanMorphology

    package init(morphology: KoreanMorphology) { self.morphology = morphology }

    package nonisolated func failureOutcome(_ error: any Error) -> WritingProviderOutcome {
        if let native = error as? KoreanNativeError, native == .unavailable { return .init(providerID: id, status: .unavailable, reason: .resource) }
        if let morphology = error as? KoreanMorphologyError, case .unsupportedInput = morphology { return .init(providerID: id, status: .unavailable, reason: .unsupportedInput) }
        return .init(providerID: id, status: .failed, reason: .provider)
    }

    package func analyze(_ request: WritingDiagnosticsRequest) async throws -> [WritingDiagnostic] {
        let collector = KoreanDiagnosticsCollector()
        try await analyzeChunks(request) { chunk in
            guard chunk.unsupportedRanges.isEmpty else { throw KoreanMorphologyError.unsupportedInput }
            await collector.append(chunk.diagnostics)
        }
        return (await collector.values).sorted { $0.range.location == $1.range.location ? $0.id < $1.id : $0.range.location < $1.range.location }
    }

    /// Await the consumer before admitting another native window; every report owns its session.
    package func analyzeChunks(_ request: WritingDiagnosticsRequest,
                       emit: @escaping @Sendable (KoreanDiagnosticsChunk) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard request.languageTag.lowercased().split(separator: "-").first == "ko" else { return }
        let source = request.text as NSString, total = source.length
        guard !request.text.utf16.contains(0), request.scope == .document || total <= 4096 else { throw KoreanMorphologyError.invalidInput }
        var session = KoreanRuleSession(profile: request.styleProfile)
        defer { session.reset() }
        if total == 0 {
            try await emit(.init(diagnostics: [], assessedRange: .init(location: 0, length: 0), totalProseUTF16: 0, unsupportedRanges: []))
            try Task.checkCancellation(); return
        }
        let ranges = request.scope == .document ? WritingWindowSplitter.ranges(in: request.text)
            : AnySequence([WritingDiagnosticRange(location: 0, length: total)])
        var cursor = 0
        for window in ranges {
            try Task.checkCancellation()
            let range = window.nsRange
            guard range.location <= cursor, range.upperBound > cursor else { throw KoreanMorphologyError.unsupportedInput }
            var analysis = try await morphology.analyze(source.substring(with: range))
            try Task.checkCancellation()
            guard analysis.unsupportedRanges.isEmpty else { throw KoreanMorphologyError.unsupportedInput }
            let final = range.upperBound == total
            let end: Int
            if final { end = total }
            else {
                let proposed = range.upperBound - min(128, range.length / 2)
                end = source.rangeOfComposedCharacterSequence(at: proposed).location
            }
            guard end > cursor, end <= range.upperBound else { throw KoreanMorphologyError.unsupportedInput }
            let ownership = NSRange(location: cursor, length: end - cursor)
            analysis.ownedRange = .init(location: cursor - range.location, length: ownership.length)
            let findings = session.consume(analysis, proseOffset: range.location, final: final)
            guard session.acceptsInput else { throw KoreanMorphologyError.invalidInput }
            try Task.checkCancellation()
            try await emit(.init(diagnostics: findings, assessedRange: .init(ownership), totalProseUTF16: total, unsupportedRanges: session.unsupportedRanges))
            try Task.checkCancellation()
            cursor = end
            await Task.yield()
        }
        guard cursor == total else { throw KoreanMorphologyError.unsupportedInput }
    }
}

private actor KoreanDiagnosticsCollector {
    package var values: [WritingDiagnostic] = []
    package func append(_ values: [WritingDiagnostic]) { self.values += values }
}
