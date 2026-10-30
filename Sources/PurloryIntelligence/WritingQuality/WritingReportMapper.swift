import CryptoKit
import Foundation

/// Report-only reconstruction. It never owns or mutates the controller's local findings.
actor WritingReportMapper {
    package struct Update: Sendable { let findings: [WritingDiagnosticsFinding]; let completed: Int }
    private let projection: WritingProjectionSnapshot
    private let sourceRevision: String
    private let profile: WritingStyleRecord
    private let identity: ProjectRuntimeIdentity
    private let profileRevision: UInt64
    private let providerRevision: String
    private let ruleRevision: Int
    private let prose: NSString
    private var processedProse = 0, completed = 0
    private var resultCoverage = WritingDiagnosticsCoverage()
    private var partial = false
    private var coverageWasTruncated = false
    private let coverageBudgetBytes: Int
    private let findingBudgetBytes: Int

    package init(projection: WritingProjectionSnapshot, prose: String, sourceRevision: String, profile: WritingStyleRecord,
         identity: ProjectRuntimeIdentity, profileRevision: UInt64, providerRevision: String, ruleRevision: Int,
         coverageBudgetBytes: Int = 16 * 1024 * 1024, findingBudgetBytes: Int = 16 * 1024 * 1024) {
        self.projection = projection; self.prose = prose as NSString; self.sourceRevision = sourceRevision
        self.profile = profile; self.identity = identity; self.profileRevision = profileRevision
        self.providerRevision = providerRevision; self.ruleRevision = ruleRevision
        self.coverageBudgetBytes = max(0, coverageBudgetBytes)
        self.findingBudgetBytes = max(0, findingBudgetBytes)
    }
    package func consume(_ chunk: KoreanDiagnosticsChunk) throws -> Update {
        try Task.checkCancellation()
        let range = chunk.assessedRange.nsRange
        guard valid(range, length: projection.proseLength), range.location == processedProse,
              chunk.totalProseUTF16 == projection.proseLength else { throw KoreanMorphologyError.invalidInput }
        let segments = projection.segments(inProse: chunk.assessedRange)
        let eligible = segments.filter(\.eligible).map { WritingDiagnosticRange($0.source) }
        completed += eligible.reduce(0) { $0 + $1.length }; processedProse = range.upperBound
        if !coverageWasTruncated && (resultCoverage.assessed.count + eligible.count) * 64 <= coverageBudgetBytes {
            resultCoverage.assessed = merge(resultCoverage.assessed + eligible)
        } else { truncateCoverage() }
        var newlyUnsupported = segments.filter(\.unsupported).map { WritingDiagnosticRange($0.source) }
        for unsupported in chunk.unsupportedRanges {
            guard valid(unsupported.nsRange, length: projection.proseLength) else { throw KoreanMorphologyError.invalidInput }
            let source = projection.segments(inProse: unsupported).filter(\.eligible).map { WritingDiagnosticRange($0.source) }
            newlyUnsupported += source
        }
        resultCoverage.unsupported = merge(resultCoverage.unsupported + newlyUnsupported)
        if coverageWasTruncated || (resultCoverage.assessed.count + resultCoverage.unsupported.count) * 64 > coverageBudgetBytes {
            truncateCoverage()
        } else {
            for unsupported in newlyUnsupported {
                resultCoverage.assessed = subtract(unsupported.nsRange, from: resultCoverage.assessed)
                if (resultCoverage.assessed.count + resultCoverage.unsupported.count) * 64 > coverageBudgetBytes {
                    truncateCoverage(); break
                }
            }
        }
        var findings: [WritingDiagnosticsFinding] = [], seen = Set<String>(), findingBytes = 0
        for diagnostic in chunk.diagnostics {
            try Task.checkCancellation()
            guard validFindingRange(diagnostic.range), diagnostic.relatedRanges.allSatisfy(validFindingRange),
                  let primary = projection.sourceRanges(forProse: diagnostic.range), let first = primary.first, let last = primary.last,
                  let piece = projection.sourcePiece(containing: first.location) else { partial = true; continue }
            let related = diagnostic.relatedRanges.compactMap { projection.sourceRanges(forProse: $0) }
            guard related.count == diagnostic.relatedRanges.count else { partial = true; continue }
            let entire = WritingDiagnosticRange(location: first.location, length: last.location + last.length - first.location)
            let intentional = profile.intentionalOccurrences.contains { occurrence in
                occurrence.ruleID == diagnostic.ruleID && occurrence.sourceRevision == sourceRevision
                    && occurrence.evidence.documentID == identity.key.documentID && occurrence.evidence.utf16Hint == first.location
                    && projection.matchesSource(occurrence.evidence.quote, in: entire)
            }
            if intentional { continue }
            // A whole-sentence pattern can span a manuscript; evidence is a bounded original prefix.
            let evidenceRange = WritingDiagnosticRange(location: first.location,
                length: min(first.length, piece.range.location + piece.range.length - first.location))
            guard let quote = projection.sourceText(in: evidenceRange), !quote.isEmpty else { partial = true; continue }
            let evidence = EvidenceAnchor(documentID: identity.key.documentID, quote: quote, utf16Hint: first.location)
            let discriminator = "\(diagnostic.providerID)|\(diagnostic.ruleID)|\(identity.key.documentID.rawValue)|\(piece.block.id)|\(first.location - piece.range.location)|\(quote)"
            let id = SHA256.hash(data: Data(discriminator.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(id).inserted else { continue }
            let relatedEvidence = related.compactMap { projection.boundedEvidence(for: $0, documentID: identity.key.documentID) }
            guard relatedEvidence.count == related.count else { partial = true; continue }
            let stamp = WritingDiagnosticsStamp(runtime: identity, nativeRevision: 0, profileRevision: profileRevision,
                providerRevision: providerRevision, ruleRevision: ruleRevision, windowDigest: sourceRevision)
            let finding = WritingDiagnosticsFinding(id: id, diagnostic: diagnostic, sourceRanges: primary, relatedSourceRanges: related,
                evidence: evidence, relatedEvidence: relatedEvidence, contextRange: entire, stamp: stamp)
            let cost = WritingDiagnosticsCache.findingCost(finding)
            guard cost <= findingBudgetBytes, findingBytes <= findingBudgetBytes - cost else { partial = true; break }
            findingBytes += cost; findings.append(finding)
        }
        return Update(findings: findings, completed: completed)
    }
    package func finish() -> WritingDiagnosticsCoverage {
        resultCoverage.isComplete = processedProse == projection.proseLength && completed == projection.eligibleProseLength
            && resultCoverage.unsupported.isEmpty && resultCoverage.dirty.isEmpty && !partial
        return resultCoverage
    }
    /// Once exact coverage exceeds its budget, retain conservative bounds rather than
    /// allowing either the dirty or unsupported fallback itself to grow without limit.
    private func truncateCoverage() {
        partial = true; coverageWasTruncated = true
        resultCoverage.assessed.removeAll()
        resultCoverage.dirty = projection.sourceLength == 0 ? [] : [.init(location: 0, length: projection.sourceLength)]
        if let first = resultCoverage.unsupported.first, let last = resultCoverage.unsupported.last {
            resultCoverage.unsupported = [.init(location: first.location, length: last.nsRange.upperBound - first.location)]
        }
    }
    private func valid(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.location <= length && range.length >= 0 && range.length <= length - range.location
    }
    private func validFindingRange(_ range: WritingDiagnosticRange) -> Bool {
        valid(range.nsRange, length: prose.length) && range.length > 0
            && prose.rangeOfComposedCharacterSequences(for: range.nsRange) == range.nsRange
    }
    private func merge(_ ranges: [WritingDiagnosticRange]) -> [WritingDiagnosticRange] {
        var result: [WritingDiagnosticRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, last.nsRange.upperBound >= range.location {
                result[result.count - 1].length = max(last.nsRange.upperBound, range.nsRange.upperBound) - last.location
            } else { result.append(range) }
        }
        return result
    }
    private func subtract(_ cut: NSRange, from ranges: [WritingDiagnosticRange]) -> [WritingDiagnosticRange] {
        var result: [WritingDiagnosticRange] = []
        for item in ranges {
            let value = item.nsRange
            guard NSIntersectionRange(value, cut).length > 0 else { result.append(item); continue }
            if value.location < cut.location { result.append(.init(location: value.location, length: cut.location - value.location)) }
            if value.upperBound > cut.upperBound { result.append(.init(location: cut.upperBound, length: value.upperBound - cut.upperBound)) }
        }
        return result
    }
}
