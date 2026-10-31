import Foundation
import SQLite3
import Darwin

/// One synchronous connection per storage lease. Never used on the prediction path.
/// Only rebuildable data belongs in this database; writer records stay in UserData.
final class IntelligenceDatabase {
    static let fileName = "knowledge.sqlite3"
    static let companions = [fileName + "-wal", fileName + "-shm", fileName + "-journal"]
    struct Failure: Error {
        let code: Int32
        let message: String
        var isCorruption: Bool { code & 0xff == SQLITE_CORRUPT || code & 0xff == SQLITE_NOTADB }
    }
    enum Value { case text(String), blob(Data), integer(Int64) }
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Retry only a proven corrupt derived database. All paths are validated again
    /// before removal; busy, denied, cancelled and constraint failures preserve it.
    static func withConnection<T>(at url: URL, _ operation: (IntelligenceDatabase) throws -> T) throws -> T {
        do { return try open(at: url, operation) }
        catch let error as Failure where error.isCorruption {
            try Task.checkCancellation()
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let file = URL(fileURLWithPath: url.path + suffix)
                try ProjectPaths.rejectSymlink(file)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            return try open(at: url, operation)
        }
    }

    private static func open<T>(at url: URL, _ operation: (IntelligenceDatabase) throws -> T) throws -> T {
        let database = try IntelligenceDatabase(url: url)
        defer { database.close() }
        return try operation(database)
    }

    private init(url: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try ProjectPaths.rejectSymlink(URL(fileURLWithPath: url.path + suffix))
        }
        // Foundation retains macOS's /var alias even after resolvingSymlinksInPath.
        // SQLite NOFOLLOW rejects that system ancestor. Resolve the already-checked
        // directory with realpath, then keep NOFOLLOW for the actual SQLite open.
        guard let directory = realpath(url.deletingLastPathComponent().path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(directory) }
        let path = String(cString: directory) + "/" + url.lastPathComponent
        let code = sqlite3_open_v2(path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let error = failure(code); close(); throw error
        }
        do {
            sqlite3_busy_timeout(handle, 250)
            sqlite3_progress_handler(handle, 1000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA trusted_schema=OFF")
            var version: Int64 = 0
            try query("PRAGMA user_version") { version = sqlite3_column_int64($0, 0) }
            guard version == 0 || version == 1 else { throw Failure(code: SQLITE_SCHEMA, message: "Unsupported intelligence schema") }
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE sidecars(scope TEXT PRIMARY KEY, metadata BLOB NOT NULL)")
                    try execute("CREATE TABLE scene_records(scope TEXT NOT NULL, hash TEXT NOT NULL, digest TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(scope,hash))")
                    try execute("CREATE TABLE sources(id INTEGER PRIMARY KEY, scope TEXT NOT NULL UNIQUE, document_id TEXT NOT NULL, digest TEXT NOT NULL, body TEXT NOT NULL, literal_fallback INTEGER NOT NULL)")
                    try execute("CREATE VIRTUAL TABLE source_fts USING fts5(body, content='sources', content_rowid='id', tokenize='trigram')")
                    try execute("PRAGMA user_version=1")
                }
            }
        } catch { close(); throw error }
    }

    deinit { close() }
    private func close() { if let handle { sqlite3_close_v2(handle); self.handle = nil } }
    private func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed")
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK", checkingCancellation: false) } }
        let result = try operation()
        try Task.checkCancellation()
        try execute("COMMIT")
        committed = true
        return result
    }
    func execute(_ sql: String, _ values: [Value] = [], checkingCancellation: Bool = true) throws {
        try query(sql, values, checkingCancellation: checkingCancellation) { _ in }
    }
    func query(_ sql: String, _ values: [Value] = [], checkingCancellation: Bool = true,
               row: (OpaquePointer) throws -> Void) throws {
        if checkingCancellation { try Task.checkCancellation() }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw failure(prepared) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1), code: Int32
            switch value {
            case .text(let text):
                guard text.utf8.count < Int32.max else { throw failure(SQLITE_TOOBIG) }
                code = text.withCString { sqlite3_bind_text(statement, position, $0, Int32(text.utf8.count), Self.transient) }
            case .blob(let bytes):
                guard bytes.count < Int32.max else { throw failure(SQLITE_TOOBIG) }
                code = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(bytes.count), Self.transient) }
            case .integer(let number): code = sqlite3_bind_int64(statement, position, number)
            }
            guard code == SQLITE_OK else { throw failure(code) }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            if code == SQLITE_INTERRUPT, Task<Never, Never>.isCancelled { throw CancellationError() }
            guard code == SQLITE_ROW else { throw failure(code) }
            try row(statement)
        }
    }
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    static func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
    static func scopeKey(_ scope: StoryMemoryScope) -> String {
        switch scope {
        case .project(let project, let document): "\(project.rawValue.uuidString)/\(document.rawValue.uuidString)"
        case .legacy(let document): "legacy/\(document.rawValue.uuidString)"
        }
    }
}
