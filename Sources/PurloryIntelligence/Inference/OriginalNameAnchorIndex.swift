import Foundation

/// Prepared original evidence only. Build off the prediction path; query scans
/// the bounded recent window and binary-searches per-character occurrences.
public struct OriginalNameAnchorIndex: Sendable, Equatable {
    public struct Anchor: Sendable, Equatable {
        public let evidence: EvidenceAnchor
        public let utf16Range: Range<Int>
        public let stableKey: String
        fileprivate let mention: Int
    }
    private struct Name: Sendable, Equatable {
        let text: String
        let characterID: UUID
    }
    private struct Relative: Sendable, Equatable {
        let characterID: UUID
        let quote: String
        let range: Range<Int>
        let mention: Int
    }
    public let documentID: UUID
    private let names: [Name]
    private let scenes: [String: [Relative]]
    private let occurrences: [UUID: [Anchor]]
    /// Extraction count, used to verify incremental reuse rather than timing.
    package let extractedSceneCount: Int

    public static func make(
        body: String, documentID: UUID, characters: [CharacterCard],
        previous: OriginalNameAnchorIndex? = nil
    ) throws -> Self {
        try Task.checkCancellation()
        var owners: [String: Set<UUID>] = [:]
        for card in characters {
            for raw in [card.name] + card.aliases.split(separator: ",").map(String.init) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 80 else { continue }
                owners[name, default: []].insert(card.id)
            }
        }
        let names = owners.compactMap { text, ids -> Name? in
            guard ids.count == 1, let id = ids.first else { return nil }
            return Name(text: text, characterID: id)
        }.sorted { $0.text.count == $1.text.count ? $0.text < $1.text : $0.text.count > $1.text.count }
        // Large or ambiguous registries remain quiet rather than partially infer.
        let boundedNames = names.count <= 256 ? names : []
        let reusable = previous?.documentID == documentID && previous?.names == boundedNames
            ? previous?.scenes ?? [:] : [:]
        let outline = DocumentOutline.parse(body)
        var scenes: [String: [Relative]] = [:], occurrences: [UUID: [Anchor]] = [:]
        var extracted = 0
        for scene in outline.scenes {
            try Task.checkCancellation()
            let relative: [Relative]
            if let cached = reusable[scene.contentHash] {
                relative = cached
            } else if let range = Range(NSRange(scene.utf16Range), in: body) {
                relative = try extract(body[range], names: boundedNames)
                extracted += 1
            } else {
                continue
            }
            scenes[scene.contentHash] = relative
            for value in relative {
                let start = scene.utf16Range.lowerBound
                let evidence = EvidenceAnchor(documentID: WritingDocumentID(rawValue: documentID),
                    sceneHash: scene.contentHash, quote: value.quote,
                    utf16Hint: start + value.range.lowerBound)
                let key = "original-name|\(value.characterID.uuidString)|\(DocumentOutline.stableHash(value.quote))"
                occurrences[value.characterID, default: []].append(Anchor(evidence: evidence,
                    utf16Range: (start + value.range.lowerBound)..<(start + value.range.upperBound),
                    stableKey: key, mention: start + value.mention))
            }
        }
        return Self(documentID: documentID, names: boundedNames, scenes: scenes,
            occurrences: occurrences.mapValues { $0.sorted { $0.mention < $1.mention } },
            extractedSceneCount: extracted)
    }

    public func latest(in window: String, startingAt windowStart: Int) -> Anchor? {
        guard windowStart >= 0,
            let visible = Self.matches(window, names: names).max(by: { $0.range.lowerBound < $1.range.lowerBound }),
            let candidates = occurrences[visible.id] else { return nil }
        var low = 0, high = candidates.count
        while low < high {
            let mid = (low + high) / 2
            if candidates[mid].mention < windowStart { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let last = candidates[low - 1]
        // Never substitute an older sentence when the latest mention overlaps C.
        return last.utf16Range.upperBound <= windowStart && last.evidence.quote.utf16.count <= 500
            && !last.evidence.quote.hasPrefix("#") ? last : nil
    }

    private static func extract(_ text: Substring, names: [Name]) throws -> [Relative] {
        var result: [Relative] = []
        for piece in DocumentOutline.sentencePieces(in: text) {
            try Task.checkCancellation()
            let raw = text[piece]
            let quote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty,
                let range = raw.range(of: quote) else { continue }
            let offset = text[..<range.lowerBound].utf16.count
            for match in matches(quote, names: names) {
                result.append(Relative(characterID: match.id, quote: quote,
                    range: offset..<(offset + quote.utf16.count),
                    mention: offset + match.range.lowerBound))
            }
        }
        return result
    }

    private static func matches(_ text: String, names: [Name]) -> [(id: UUID, range: Range<Int>)] {
        func word(_ char: Character) -> Bool {
            char == "_" || char.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        var result: [(id: UUID, range: Range<Int>)] = []
        for name in names {
            var start = text.startIndex
            while start < text.endIndex,
                let range = text.range(of: name.text, range: start..<text.endIndex) {
                start = range.upperBound
                guard range.lowerBound == text.startIndex || !word(text[text.index(before: range.lowerBound)]) else { continue }
                var end = range.upperBound
                while end < text.endIndex, word(text[end]) { end = text.index(after: end) }
                let suffix = String(text[range.upperBound..<end])
                guard suffix.isEmpty || CharacterLexicon.base.particles.contains(where: { $0.suffix == suffix }) else { continue }
                let offset = text[..<range.lowerBound].utf16.count
                let location = offset..<(offset + text[range].utf16.count)
                guard !result.contains(where: { $0.range.overlaps(location) }) else { continue }
                result.append((name.characterID, location))
            }
        }
        return result
    }
}
