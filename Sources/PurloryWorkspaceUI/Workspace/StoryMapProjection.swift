import CryptoKit
import Foundation

struct StoryMapProjection: Equatable, Sendable {
    enum Order: String, CaseIterable, Sendable { case manuscript, chronology }
    enum Kind: Sendable { case scene, event }
    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let kind: Kind
        let title: String
        let sceneID: String
        let sourceRange: Range<Int>
        let evidence: EvidenceAnchor
        let characterIDs: Set<UUID>
        let threadIDs: Set<String>
        let laneSlots: [Int]
    }
    struct Character: Equatable, Sendable, Identifiable { let id: UUID; let title: String }
    struct Thread: Equatable, Sendable, Identifiable { let id: String; let title: String; let slot: Int }
    let revision: String
    let sourceLength: Int
    let scenes: [Row]
    let rows: [Row]
    let characters: [Character]
    let threads: [Thread]
    static func build(_ document: ProjectDocumentSnapshot, knowledge: KnowledgeSnapshot? = nil,
                      knowledgeOrigin: ProjectRuntimeIdentity? = nil, order: Order = .manuscript) async throws -> Self {
        try Task.checkCancellation()
        let revision = SHA256.hash(data: Data(document.body.utf8)).map { String(format: "%02x", $0) }.joined()
        let length = document.body.utf16.count
        func result(scenes: [Row], rows: [Row], characters: [Character] = [], threads: [Thread] = []) -> Self {
            .init(revision: revision, sourceLength: length, scenes: scenes, rows: rows, characters: characters, threads: threads)
        }
        guard document.mode == .fiction, document.kind == .manuscript else { return result(scenes: [], rows: []) }
        let scope = StoryMemoryScope.project(projectID: document.identity.key.projectID, documentID: document.identity.key.documentID)
        let verified = knowledge.flatMap { value -> KnowledgeSnapshot? in
            guard knowledgeOrigin == document.identity, value.entryID == scope.documentID.rawValue,
                  let original = value.storyKnowledge, original.scope == scope,
                  original.sourceRevision == revision, original.sourceLength == length else { return nil }
            return value
        }
        let outline = verified?.outline ?? DocumentOutline.parse(document.body)
        let text = document.body as NSString
        var scenes: [Row] = []
        for (index, scene) in outline.scenes.enumerated() {
            if index.isMultiple(of: 32) { await Task.yield(); try Task.checkCancellation() }
            let range = scene.utf16Range
            guard range.lowerBound >= 0, range.upperBound <= length, !range.isEmpty else { continue }
            let source = text.substring(with: NSRange(location: range.lowerBound, length: range.count))
            guard DocumentOutline.stableHash(source) == scene.contentHash else { continue }
            var quote = "", count = 0
            for scalar in source.unicodeScalars {
                guard count + scalar.utf16.count <= 256 else { break }
                quote.unicodeScalars.append(scalar); count += scalar.utf16.count
                if scalar == "\n" { break }
            }
            guard !quote.isEmpty else { continue }
            let id = "scene:\(range.lowerBound)", path = scene.headingPath.filter { !$0.isEmpty }.joined(separator: " › ")
            let meta = verified?.sceneMetaByHash[scene.contentHash]
            let writerTitle = meta?.titleUserEdited == true ? meta?.title : nil
            let title = writerTitle.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? (path.isEmpty ? "장면 \(index + 1)" : path)
            scenes.append(.init(id: id, kind: .scene, title: title,
                sceneID: id, sourceRange: range,
                evidence: .init(documentID: scope.documentID, quote: quote, utf16Hint: range.lowerBound),
                characterIDs: [], threadIDs: [], laneSlots: []))
        }
        guard let verified, verified.canonicalEvents.count + outline.scenes.count <= 8192,
              verified.plotThreads.count <= 128,
              verified.canonicalEvents.reduce(0, { $0 + $1.perspectives.count }) <= 8192,
              verified.segmentsByScene.values.reduce(0, { $0 + $1.count }) <= 8192,
              verified.plotThreads.reduce(0, { $0 + $1.memberKeys.count }) <= 65536,
              Set(outline.scenes.map(\.contentHash)).count == outline.scenes.count else {
            return result(scenes: scenes, rows: scenes)
        }
        let byStart = Dictionary(uniqueKeysWithValues: scenes.map { ($0.sourceRange.lowerBound, $0) })
        let sourceByHash = Dictionary(uniqueKeysWithValues: outline.scenes.map { ($0.contentHash, $0.utf16Range) })
        let expanded = Set(outline.scenes.map { $0.contentHash + "-minor" })
        let graph = order == .manuscript ? GraphRow.flowRows(from: verified, expandedMinors: expanded) : GraphRow.chronoRows(from: verified)
        var mapped: [(GraphRow, Row)] = []
        for (index, row) in graph.enumerated() {
            if index.isMultiple(of: 32) { await Task.yield(); try Task.checkCancellation() }
            switch row {
            case .sceneMarker(let info):
                if let scene = byStart[info.start] { mapped.append((row, scene)) }
            case .event(_, let event, _):
                guard let bounds = sourceByHash[event.sceneHash], let scene = byStart[bounds.lowerBound],
                      let quote = event.quote, !quote.isEmpty, quote.utf16.count <= 1024,
                      let original = SourceAnchor.uniqueOriginalRange(for: quote, in: document.body,
                          within: NSRange(location: bounds.lowerBound, length: bounds.count)) else { continue }
                mapped.append((row, .init(id: "event:" + event.canonicalKey, kind: .event,
                    title: event.summary, sceneID: scene.id, sourceRange: original.location..<(original.location + original.length),
                    evidence: .init(documentID: scope.documentID, quote: quote, utf16Hint: original.location),
                    characterIDs: Set(event.participants), threadIDs: Set(verified.threadIDsByEvent[event.canonicalKey] ?? []), laneSlots: [])))
            default: break
            }
        }
        try Task.checkCancellation()
        let layout = ThreadGraphLayout.compute(rows: mapped.map { $0.0 }, threads: verified.plotThreads)
        let rows = mapped.map { graphRow, row -> Row in
            guard let key = graphRow.eventKey else { return row }
            return .init(id: row.id, kind: row.kind, title: row.title, sceneID: row.sceneID, sourceRange: row.sourceRange,
                evidence: row.evidence, characterIDs: row.characterIDs, threadIDs: row.threadIDs, laneSlots: layout.nodes[key]?.laneSlots ?? [])
        }
        let participants = rows.reduce(into: Set<UUID>()) { $0.formUnion($1.characterIDs) }
        try Task.checkCancellation()
        return result(scenes: scenes, rows: rows.contains(where: { $0.kind == .event }) ? rows : scenes,
            characters: verified.characters.filter { participants.contains($0.id) }.map { .init(id: $0.id, title: $0.name) },
            threads: layout.lanes.map { .init(id: $0.thread.id, title: $0.thread.title, slot: $0.slot) })
    }
    func filtered(threadID: String?, characterID: UUID?) -> [Row] {
        guard threadID != nil || characterID != nil else { return rows }
        let events = rows.filter { row in
            row.kind == .event && (threadID.map { row.threadIDs.contains($0) } ?? true)
                && (characterID.map { row.characterIDs.contains($0) } ?? true)
        }
        let ids = Set(events.map(\.id)), visibleScenes = Set(events.map(\.sceneID))
        return rows.filter { ids.contains($0.id) || ($0.kind == .scene && visibleScenes.contains($0.sceneID)) }
    }
    func currentScene(at offset: Int) -> Row? {
        guard offset >= 0, offset <= sourceLength else { return nil }
        var low = 0, high = scenes.count
        while low < high {
            let mid = low + (high - low) / 2
            if scenes[mid].sourceRange.lowerBound <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let scene = scenes[low - 1]
        return offset < scene.sourceRange.upperBound || offset == sourceLength ? scene : nil
    }
}
