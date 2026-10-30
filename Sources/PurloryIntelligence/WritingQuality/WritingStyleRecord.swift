import Foundation

package struct WritingStyleRecord: Codable, Equatable, Sendable {
    package let version: Int
    package var profile: WritingStyleProfile
    package var languageTag: String?
    package var intentionalOccurrences: [WritingIntentionalOccurrence]

    package init(profile: WritingStyleProfile = WritingStyleProfile(dialogueSensitivity: .low),
         languageTag: String? = nil, intentionalOccurrences: [WritingIntentionalOccurrence] = []) {
        version = 1; self.profile = profile; self.languageTag = languageTag
        self.intentionalOccurrences = intentionalOccurrences
    }

    package func isLearned(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let canonical = word.precomposedStringWithCanonicalMapping
        // Swift String hashing/equality also preserves canonical equivalence for legacy NFD sets.
        return profile.learnedWords.contains(canonical)
    }
}

package struct WritingIntentionalOccurrence: Codable, Equatable, Sendable {
    package let ruleID: String
    package let evidence: EvidenceAnchor
    package let sourceRevision: String

    /// The caller supplies a revision proved at load/capture; nil after an unverified edit.
    /// Automatic checks never hash/search the full manuscript to infer suppression.
    package func suppresses(ruleID: String, evidence: EvidenceAnchor, sourceRevision: String?) -> Bool {
        self.ruleID == ruleID && sourceRevision == self.sourceRevision
            && self.evidence.documentID == evidence.documentID
            && self.evidence.utf16Hint != nil && self.evidence.utf16Hint == evidence.utf16Hint
            && self.evidence.quote.utf16.elementsEqual(evidence.quote.utf16)
    }
}

package enum WritingStyleLoad: Equatable, Sendable {
    case ready(WritingStyleRecord)
    case unreadable(original: Data, reason: String)
}

package enum WritingStyleRepositoryError: Error {
    case unreadableProfile
    case invalidRecord
    case invalidOccurrence
}
