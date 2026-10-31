import Foundation

extension IntelligenceDatabase {
    func reconcileSources(_ sources: [IndexedSource]) throws {
        try transaction {
            var existing: [String: String] = [:]
            try query("SELECT scope,digest FROM sources") { existing[Self.text($0, 0)] = Self.text($0, 1) }
            let live = Set(sources.map { Self.scopeKey($0.scope) })
            for source in sources {
                try Task.checkCancellation()
                let key = Self.scopeKey(source.scope)
                guard existing[key] != source.digest else { continue }
                if existing[key] != nil { try removeFTSRow(key) }
                try execute("INSERT INTO sources(scope,document_id,digest,body,literal_fallback) VALUES(?,?,?,?,?) ON CONFLICT(scope) DO UPDATE SET digest=excluded.digest,body=excluded.body,literal_fallback=excluded.literal_fallback",
                    [.text(key), .text(source.scope.documentID.rawValue.uuidString), .text(source.digest), .text(source.body), .integer(source.literalFallback ? 1 : 0)])
                try execute("INSERT INTO source_fts(rowid,body) SELECT id,body FROM sources WHERE scope=?", [.text(key)])
            }
            for key in Set(existing.keys).subtracting(live) {
                try removeFTSRow(key)
                try execute("DELETE FROM sources WHERE scope=?", [.text(key)])
            }
        }
    }

    private func removeFTSRow(_ key: String) throws {
        try execute("INSERT INTO source_fts(source_fts,rowid,body) SELECT 'delete',id,body FROM sources WHERE scope=?", [.text(key)])
    }

    func sourceCandidates(terms: [String]) throws -> [String: Set<WritingDocumentID>] {
        var fallback: Set<WritingDocumentID> = []
        try query("SELECT document_id FROM sources WHERE literal_fallback=1") { row in
            if let id = UUID(uuidString: Self.text(row, 0)) { fallback.insert(.init(rawValue: id)) }
        }
        var candidates: [String: Set<WritingDocumentID>] = [:]
        for term in Set(terms) where term.unicodeScalars.count >= 3 && IndexedSource.hasSafeTrigrams(term) {
            let match = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            var documents = fallback
            try query("SELECT sources.document_id FROM source_fts JOIN sources ON sources.id=source_fts.rowid WHERE source_fts MATCH ?", [.text(match)]) { row in
                if let id = UUID(uuidString: Self.text(row, 0)) { documents.insert(.init(rawValue: id)) }
            }
            candidates[term] = documents
        }
        return candidates
    }
}
