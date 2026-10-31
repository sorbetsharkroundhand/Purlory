import Foundation
import SQLite3

extension IntelligenceDatabase {
    private struct SceneRecord: Codable {
        var summary: KnowledgeSidecar.SceneSummary?
        var events: [StoryEvent]?
        var insights: SceneInsights?
        var segments: SceneSegmentation?
    }

    func loadSidecar(scope: StoryMemoryScope) throws -> KnowledgeSidecar? {
        let key = Self.scopeKey(scope)
        var metadata: Data?
        try query("SELECT metadata FROM sidecars WHERE scope=?", [.text(key)]) { metadata = Self.data($0, 0) }
        guard let metadata else { return nil }
        var sidecar = try JSONDecoder().decode(KnowledgeSidecar.self, from: metadata)
        guard sidecar.scope == scope, sidecar.schemaVersion == KnowledgeSidecar.currentSchemaVersion else {
            var fresh = KnowledgeSidecar(scope: scope)
            fresh.generation = sidecar.generation + 1
            return fresh
        }
        try query("SELECT hash,payload,digest FROM scene_records WHERE scope=?", [.text(key)]) { statement in
            let hash = Self.text(statement, 0), bytes = Self.data(statement, 1)
            guard ProjectDigest.hash(bytes) == Self.text(statement, 2) else {
                throw Failure(code: SQLITE_CORRUPT, message: "Intelligence scene checksum mismatch")
            }
            let record = try JSONDecoder().decode(SceneRecord.self, from: bytes)
            sidecar.sceneSummaries[hash] = record.summary
            sidecar.events[hash] = record.events
            sidecar.insights[hash] = record.insights
            sidecar.segments[hash] = record.segments
        }
        return sidecar
    }

    /// Changed payloads alone reach SQLite's write path. Absent and empty scene
    /// outputs remain distinct, preserving the reader's completed-work memoization.
    func saveSidecar(_ sidecar: KnowledgeSidecar, pruningTo liveHashes: Set<String>? = nil, verifying: Bool = false) throws {
        let key = Self.scopeKey(sidecar.scope)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var metadata = sidecar
        metadata.sceneSummaries = [:]; metadata.events = [:]; metadata.insights = [:]; metadata.segments = [:]
        let data = try encoder.encode(metadata)
        let hashes = Set(sidecar.sceneSummaries.keys).union(sidecar.events.keys)
            .union(sidecar.insights.keys).union(sidecar.segments.keys)
            .filter { liveHashes?.contains($0) != false }
        try transaction {
            try execute("INSERT INTO sidecars(scope,metadata) VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET metadata=excluded.metadata WHERE metadata != excluded.metadata", [.text(key), .blob(data)])
            var existing: [String: String] = [:]
            try query("SELECT hash,digest FROM scene_records WHERE scope=?", [.text(key)]) { existing[Self.text($0, 0)] = Self.text($0, 1) }
            for hash in hashes {
                try Task.checkCancellation()
                let record = SceneRecord(summary: sidecar.sceneSummaries[hash], events: sidecar.events[hash],
                    insights: sidecar.insights[hash], segments: sidecar.segments[hash])
                let bytes = try encoder.encode(record), digest = ProjectDigest.hash(bytes)
                guard existing[hash] != digest else { continue }
                try execute("INSERT INTO scene_records(scope,hash,digest,payload) VALUES(?,?,?,?) ON CONFLICT(scope,hash) DO UPDATE SET digest=excluded.digest,payload=excluded.payload",
                    [.text(key), .text(hash), .text(digest), .blob(bytes)])
            }
            for hash in Set(existing.keys).subtracting(hashes) {
                try execute("DELETE FROM scene_records WHERE scope=? AND hash=?", [.text(key), .text(hash)])
            }
            if verifying, try loadSidecar(scope: sidecar.scope) != sidecar {
                throw Failure(code: SQLITE_MISMATCH, message: "Intelligence migration verification failed")
            }
        }
    }

    func removeSidecar(scope: StoryMemoryScope) throws {
        let key = Self.scopeKey(scope)
        try transaction {
            try execute("DELETE FROM scene_records WHERE scope=?", [.text(key)])
            try execute("DELETE FROM sidecars WHERE scope=?", [.text(key)])
        }
    }
}
