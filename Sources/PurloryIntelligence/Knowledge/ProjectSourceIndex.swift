import Foundation

package struct SourceIndexPreparation: Sendable {
    package let candidates: [String: Set<WritingDocumentID>]
    package let outlines: [WritingDocumentID: DocumentOutline]
    package let revisions: [WritingDocumentID: String]
}

/// Explicit source search preparation, isolated from editor and prediction work.
public actor ProjectSourceIndex {
    private enum Unavailable: Error { case memoryPressure }
    private let store: ProjectStore
    private var memoryPressurePaused = false
    private struct Prepared: Sendable {
        let source: DocumentSource
        let row: IndexedSource
        let outline: DocumentOutline
    }
    private var projectID: WritingProjectID?
    private var prepared: [WritingDocumentID: Prepared] = [:]
    package private(set) var lastPreparedDocumentCount = 0
    public init(store: ProjectStore) { self.store = store }

    public func releaseMemory() { prepared.removeAll(); projectID = nil }
    package func setMemoryPressurePaused(_ paused: Bool) {
        memoryPressurePaused = paused
        if paused { releaseMemory() }
    }

    package func prepare(terms: [String], in project: WritingProject) async throws -> SourceIndexPreparation {
        try Task.checkCancellation()
        guard !memoryPressurePaused else { throw Unavailable.memoryPressure }
        if projectID != project.id { releaseMemory(); projectID = project.id }
        var next: [WritingDocumentID: Prepared] = [:], count = 0
        for document in project.documents where !project.trashedDocumentIDs.contains(document.id) {
            try Task.checkCancellation()
            if let cached = prepared[document.id], cached.source.isSameVersion(as: document.source) {
                next[document.id] = cached
            } else {
                let body = document.body
                next[document.id] = Prepared(source: document.source,
                    row: IndexedSource(scope: .project(projectID: project.id, documentID: document.id),
                        body: body, digest: ProjectDigest.hash(Data(body.utf8)),
                        literalFallback: !IndexedSource.hasSafeTrigrams(body)), outline: DocumentOutline.parse(body))
                count += 1
            }
        }
        try Task.checkCancellation()
        prepared = next; lastPreparedDocumentCount = count
        let rows = next.values.map(\.row), outlines = next.mapValues(\.outline)
        let candidates = try await store.withIntelligenceFile(projectID: project.id,
            name: IntelligenceDatabase.fileName, companions: IntelligenceDatabase.companions) { url in
            try IntelligenceDatabase.withConnection(at: url) { database in
                try database.reconcileSources(rows)
                return try database.sourceCandidates(terms: terms)
            }
        }
        try Task.checkCancellation()
        guard !memoryPressurePaused else { throw Unavailable.memoryPressure }
        return SourceIndexPreparation(candidates: candidates, outlines: outlines,
            revisions: next.mapValues { String($0.row.digest.prefix(16)) })
    }
}

struct IndexedSource: Sendable {
    let scope: StoryMemoryScope
    let body: String
    let digest: String
    let literalFallback: Bool

    /// Foundation's case-insensitive Unicode search is broader than SQLite's fold.
    /// Only ASCII and composed Hangul letters prove trigram exclusion. Other scripts,
    /// decomposed marks and short terms keep the literal search fallback.
    static func hasSafeTrigrams(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            if scalar.value == 0 { return false }
            if scalar.isASCII || (0xAC00...0xD7A3).contains(scalar.value) { return true }
            return !CharacterSet.letters.contains(scalar) && !CharacterSet.nonBaseCharacters.contains(scalar)
        }
    }
}
