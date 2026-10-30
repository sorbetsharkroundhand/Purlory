import Foundation

/// ProjectSession remains the only storage owner. Reading is strictly nonmutating.
@MainActor
package enum WritingStyleRepository {
    package static let key = "writing-style-profile"
    private static let profileKeys: Set<String> = ["ignoredRuleIDs", "learnedWords", "repetitionSensitivity", "dialogueSensitivity"]

    package static func read(_ snapshot: ProjectDocumentSnapshot) -> WritingStyleLoad {
        guard let bytes = snapshot.userData[key] else { return .ready(WritingStyleRecord()) }
        do {
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw WritingStyleRepositoryError.invalidRecord
            }
            let record: WritingStyleRecord
            if object["version"] != nil {
                guard keys(object, within: ["version", "profile", "languageTag", "intentionalOccurrences"]),
                      let profile = object["profile"] as? [String: Any], keys(profile, within: profileKeys),
                      let occurrences = object["intentionalOccurrences"] as? [[String: Any]],
                      occurrences.allSatisfy(validOccurrenceSchema) else { throw WritingStyleRepositoryError.invalidRecord }
                record = try JSONDecoder().decode(WritingStyleRecord.self, from: bytes)
                guard valid(record) else { throw WritingStyleRepositoryError.invalidRecord }
            } else {
                guard keys(object, within: profileKeys) else { throw WritingStyleRepositoryError.invalidRecord }
                // Value-only profiles retain the previous standard/standard defaults.
                record = WritingStyleRecord(profile: try JSONDecoder().decode(WritingStyleProfile.self, from: bytes))
            }
            return .ready(record)
        } catch {
            // Never expose decoder payloads (which may contain learned words) as diagnostics.
            return .unreadable(original: bytes, reason: "저장된 교정 설정을 읽을 수 없습니다. 원본은 보존됩니다.")
        }
    }

    /// Explicit user action: full-source revision capture is allowed here, never on typing.
    package static func captureIntentional(ruleID: String, range: WritingDiagnosticRange,
                                   in snapshot: ProjectDocumentSnapshot) throws -> WritingIntentionalOccurrence {
        let ns = snapshot.body as NSString, bounds = range.nsRange
        guard !ruleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bounds.location >= 0, bounds.location <= ns.length, bounds.length > 0,
              bounds.length <= ns.length - bounds.location,
              ns.rangeOfComposedCharacterSequences(for: bounds) == bounds else { throw WritingStyleRepositoryError.invalidOccurrence }
        return WritingIntentionalOccurrence(ruleID: ruleID,
            evidence: EvidenceAnchor(documentID: snapshot.identity.key.documentID,
                                     quote: ns.substring(with: bounds), utf16Hint: bounds.location),
            sourceRevision: DocumentOutline.stableHash(snapshot.body))
    }

    /// Deliberate re-anchoring uses exact original evidence, declining edited duplicates.
    package static func reanchor(_ occurrence: WritingIntentionalOccurrence,
                         in snapshot: ProjectDocumentSnapshot) -> WritingIntentionalOccurrence? {
        guard occurrence.evidence.documentID == snapshot.identity.key.documentID,
              let range = SourceAnchor.exactRange(for: occurrence.evidence, in: snapshot.body,
                                                revision: occurrence.sourceRevision),
              (snapshot.body as NSString).substring(with: range).utf16.elementsEqual(occurrence.evidence.quote.utf16) else { return nil }
        return try? captureIntentional(ruleID: occurrence.ruleID, range: .init(range), in: snapshot)
    }

    package static func valid(_ record: WritingStyleRecord) -> Bool {
        record.version == 1 && record.intentionalOccurrences.allSatisfy {
            !$0.ruleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.evidence.quote.isEmpty && !$0.sourceRevision.isEmpty
                && ($0.evidence.utf16Hint.map { $0 >= 0 } ?? true)
        }
    }
    private static func keys(_ object: [String: Any], within known: Set<String>) -> Bool {
        Set(object.keys).isSubset(of: known)
    }
    private static func validOccurrenceSchema(_ object: [String: Any]) -> Bool {
        guard keys(object, within: ["ruleID", "evidence", "sourceRevision"]),
              let evidence = object["evidence"] as? [String: Any],
              keys(evidence, within: ["documentID", "sceneHash", "quote", "utf16Hint"]),
              let document = evidence["documentID"] as? [String: Any], keys(document, within: ["rawValue"]) else { return false }
        return true
    }
}
