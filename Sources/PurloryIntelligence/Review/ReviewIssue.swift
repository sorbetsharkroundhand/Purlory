import CryptoKit
import Foundation

/// Prepared inspection data; neither model prose nor a derived ID grants source authority.
package struct ReviewIssue: Equatable, Sendable, Identifiable {
    package enum Category: String, CaseIterable, Sendable { case continuity, characters, timeline, dialogue, openThreads, structure }
    package enum Severity: Int, Sendable { case review, note }
    package let id: String
    package let identity: ProjectRuntimeIdentity
    package let revision: String
    package let category: Category
    package let severity: Severity
    package let title: String
    package let message: String
    package let evidence: [EvidenceAnchor]
    package let candidate: ContinuityCandidate?
    package var requiresJudging: Bool { candidate?.requiresJudging ?? false }
    package var sourceOrder: Int { evidence.first?.utf16Hint ?? .max }
    private init(id: String, context: ReviewOriginalContext, category: Category, severity: Severity,
                 title: String, message: String, evidence: [EvidenceAnchor], candidate: ContinuityCandidate?) {
        self.id = id; identity = context.document.identity; revision = context.revision
        self.category = category; self.severity = severity; self.title = title; self.message = message
        self.evidence = evidence; self.candidate = candidate
    }
    package static func prepare(logicalID: String, category: Category, severity: Severity = .note, title: String,
                        message: String, evidence: [EvidenceAnchor], candidate: ContinuityCandidate? = nil,
                        context: ReviewOriginalContext) -> Self? {
        guard !logicalID.isEmpty, logicalID.utf16.count <= 1024, !message.isEmpty, message.utf16.count <= 500,
              let originals = context.validated(evidence), (severity != .review && candidate == nil) || originals.count >= 2 else { return nil }
        // The factory itself enforces authority, independently from its projection caller.
        if let candidate {
            guard category == Self.category(for: candidate.kind), candidate.scope == .project(projectID: context.document.identity.key.projectID, documentID: context.document.identity.key.documentID),
                  candidate.sourceRevision == context.revision, let supplied = context.validated(candidate.evidence), supplied.count == originals.count,
                  zip(supplied, originals).allSatisfy({ $0.utf16Hint == $1.utf16Hint && $0.quote.utf16.count == $1.quote.utf16.count }),
                  !candidate.requiresJudging || severity == .note else { return nil }
        }
        if severity == .review {
            guard let candidate, !candidate.requiresJudging,
                  candidate.kind == .deadSpeaker || candidate.kind == .honorificBreak else { return nil }
        }
        let key = [context.document.identity.key.projectID.rawValue.uuidString, context.document.identity.key.documentID.rawValue.uuidString,
                   category.rawValue, logicalID]
        guard let bytes = try? JSONEncoder().encode(key) else { return nil }
        let id = "review.v1." + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(id: id, context: context, category: category, severity: severity, title: title,
            message: message, evidence: originals, candidate: candidate)
    }
    package static func category(for kind: ContinuityCandidate.Kind) -> Category {
        switch kind {
        case .deadSpeaker, .objectReappearance: .continuity
        case .knowledgeLeak, .relationshipIdentity: .characters
        case .locationOverlap, .ageArithmetic: .timeline
        case .honorificBreak: .dialogue
        }
    }

}

/// Exists only during utility preparation; output issues retain bounded originals, not the body.
package struct ReviewOriginalContext {
    package let document: ProjectDocumentSnapshot
    package let snapshot: KnowledgeSnapshot
    package let revision: String
    private init(document: ProjectDocumentSnapshot, snapshot: KnowledgeSnapshot, revision: String) {
        self.document = document; self.snapshot = snapshot; self.revision = revision
    }
    package static func prepare(_ document: ProjectDocumentSnapshot, snapshot: KnowledgeSnapshot?, origin: ProjectRuntimeIdentity?) -> Self? {
        guard document.mode == .fiction, document.kind == .manuscript, origin == document.identity,
              let snapshot, snapshot.entryID == document.identity.key.documentID.rawValue,
              let story = snapshot.storyKnowledge,
              story.scope == .project(projectID: document.identity.key.projectID, documentID: document.identity.key.documentID),
              story.sourceLength == document.body.utf16.count else { return nil }
        let revision = SHA256.hash(data: Data(document.body.utf8)).map { String(format: "%02x", $0) }.joined()
        guard story.sourceRevision == revision else { return nil }
        return .init(document: document, snapshot: snapshot, revision: revision)
    }
    package func validated(_ evidence: [EvidenceAnchor]) -> [EvidenceAnchor]? {
        guard (1...8).contains(evidence.count) else { return nil }
        let source = document.body as NSString
        var total = 0, ranges: Set<Range<Int>> = []
        for anchor in evidence {
            let count = anchor.quote.utf16.count
            guard anchor.documentID == document.identity.key.documentID, (1...2048).contains(count),
                  let hint = anchor.utf16Hint, hint >= 0, hint <= source.length, count <= source.length - hint,
                  count <= 8192 - total, ranges.insert(hint..<(hint + count)).inserted,
                  Array(anchor.quote.utf16).enumerated().allSatisfy({ source.character(at: hint + $0.offset) == $0.element }) else { return nil }
            total += count
        }
        return evidence.sorted { ($0.utf16Hint ?? .max) < ($1.utf16Hint ?? .max) }
    }
    package func original(_ quote: String?, sceneHash: String, indices: [String: Int]) -> EvidenceAnchor? {
        guard let quote, quote.utf16.count <= 2048, let index = indices[sceneHash] else { return nil }
        let scene = snapshot.outline.scenes[index], source = document.body as NSString, range = scene.utf16Range
        guard range.lowerBound >= 0, range.upperBound <= source.length,
              DocumentOutline.stableHash(source.substring(with: NSRange(range))) == sceneHash,
              let match = SourceAnchor.uniqueOriginalRange(for: quote, in: document.body, within: NSRange(range)) else { return nil }
        return .init(documentID: document.identity.key.documentID, sceneHash: sceneHash, quote: quote, utf16Hint: match.location)
    }
}
