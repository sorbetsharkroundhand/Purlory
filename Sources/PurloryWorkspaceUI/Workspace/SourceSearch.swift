import Foundation

public enum SourceSearchScope: String, CaseIterable, Sendable { case here, chapter, project }
public enum SourceSearchPurpose: Sendable { case inspection, beforeCursor }

public struct SourceSearchHit: Identifiable, Equatable, Sendable {
    public enum Reason: Sendable { case literal, confirmedName }
    public let projectID: WritingProjectID
    public let documentID: WritingDocumentID
    public let title: String
    public let evidence: EvidenceAnchor
    public let revision: String
    public let matchedText: String
    public let matchedRange: NSRange
    public let reason: Reason
    public var id: String {
        "\(projectID.rawValue)|\(documentID.rawValue)|\(matchedRange.location)|\(revision)"
    }
}

/// Explicit model-free retrieval over immutable originals; never called during prediction.
public enum SourceSearch {
    public static func results(
        query raw: String, in project: WritingProject, origin: WritingDocumentID,
        cursor: Int, scope: SourceSearchScope, purpose: SourceSearchPurpose = .inspection,
        limit: Int = 100
    ) throws -> [SourceSearchHit] {
        try Task.checkCancellation()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf16.count <= 500, limit > 0,
              let originIndex = project.documents.firstIndex(where: { $0.id == origin }),
              !project.trashedDocumentIDs.contains(origin) else { return [] }
        let maximum = min(100, limit)
        let terms = [query] + aliases(for: query, in: project)
        var results: [SourceSearchHit] = [], seen: Set<String> = []
        // Literal originals outrank sorted alias expansions, then stored document/offset order.
        for (termIndex, term) in terms.enumerated() {
            for (documentIndex, document) in project.documents.enumerated() {
                try Task.checkCancellation()
                guard !project.trashedDocumentIDs.contains(document.id),
                      scope == .project || document.id == origin,
                      purpose != .beforeCursor || documentIndex <= originIndex else { continue }
                let body = purpose == .beforeCursor && document.id == origin
                    ? prefix(document.body, upTo: cursor) : document.body
                let ns = body as NSString, outline = DocumentOutline.parse(body)
                let boundedCursor = min(max(0, cursor), ns.length)
                let ranges: [Range<Int>]
                if scope == .project { ranges = [0..<ns.length] }
                else if let index = outline.sceneIndex(at: boundedCursor) {
                    let scene = outline.scenes[index]
                    if scope == .here { ranges = [scene.utf16Range] }
                    else {
                        let group = HierarchicalMemory.chapterGroups(in: outline)
                            .first { $0.scenes.contains(scene) }
                        if let first = group?.scenes.first, let last = group?.scenes.last {
                            ranges = [first.utf16Range.lowerBound..<last.utf16Range.upperBound]
                        } else { ranges = [] }
                    }
                } else { ranges = [] }
                for region in ranges {
                    var start = region.lowerBound
                    while start < region.upperBound {
                        try Task.checkCancellation()
                        let match = ns.range(of: term, options: .caseInsensitive,
                            range: NSRange(location: start, length: region.upperBound - start))
                        guard match.location != NSNotFound else { break }
                        start = NSMaxRange(match)
                        let identity = "\(document.id.rawValue)|\(match.location)"
                        guard seen.insert(identity).inserted else { continue }
                        let context = ns.rangeOfComposedCharacterSequences(for: NSRange(
                            location: max(region.lowerBound, match.location - 24),
                            length: min(region.upperBound, NSMaxRange(match) + 24)
                                - max(region.lowerBound, match.location - 24)))
                        let scene = outline.scenes.first { $0.utf16Range.contains(match.location) }
                        results.append(SourceSearchHit(projectID: project.id, documentID: document.id,
                            title: document.title, evidence: EvidenceAnchor(documentID: document.id,
                                sceneHash: scene?.contentHash, quote: ns.substring(with: context),
                                utf16Hint: context.location), revision: DocumentOutline.stableHash(document.body),
                            matchedText: ns.substring(with: match), matchedRange: match,
                            reason: termIndex == 0 ? .literal : .confirmedName))
                        if results.count == maximum { return results }
                    }
                }
            }
        }
        return results
    }

    private static func prefix(_ body: String, upTo cursor: Int) -> String {
        let ns = body as NSString, end = min(max(0, cursor), ns.length)
        guard end < ns.length else { return body }
        let boundary = ns.rangeOfComposedCharacterSequence(at: end).location
        return ns.substring(to: boundary)
    }

    private static func aliases(for query: String, in project: WritingProject) -> [String] {
        func folded(_ value: String) -> String {
            value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        var names: [UUID: Set<String>] = [:]
        for document in project.documents where !project.trashedDocumentIDs.contains(document.id) {
            guard let data = try? WriterDocumentData.decode(
                project.userData[WriterDocumentData.key(for: document.id)], documentID: document.id) else { continue }
            for card in data.characters where card.autoRegistered != true {
                for raw in [card.name] + card.aliases.split(separator: ",").map(String.init) {
                    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, name.count <= 80 { names[card.id, default: []].insert(name) }
                }
            }
        }
        let matching = names.filter { $0.value.contains { folded($0) == folded(query) } }
        guard matching.count == 1, let identified = matching.first else { return [] }
        return identified.value.filter { name in
            folded(name) != folded(query) && names.values.filter {
                $0.contains { folded($0) == folded(name) }
            }.count == 1
        }.sorted()
    }
}
