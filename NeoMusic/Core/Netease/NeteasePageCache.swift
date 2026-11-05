import Foundation
import SQLite3

/// Account-scoped page snapshots. Encoding and database work run on this actor.
actor NeteasePageCache {
    private let directory: URL
    private let capacity: Int
    private var connection: Connection?

    init(directory: URL, capacity: Int = 256) {
        self.directory = directory
        self.capacity = min(max(capacity, 1), 256)
    }

    func load<Value: Decodable & Sendable>(_ type: Value.Type, scope: String, key: String) throws -> Value? {
        try Task.checkCancellation()
        let database = try database()
        let query = try statement("SELECT payload FROM pageContent WHERE scope = ? AND cacheKey = ?", database: database)
        defer { sqlite3_finalize(query) }
        try bind(scope, at: 1, to: query, database: database)
        try bind(key, at: 2, to: query, database: database)
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure(database, code: status) }
        let data = payload(query, column: 0)
        try Task.checkCancellation()
        do {
            let value = try JSONDecoder().decode(type, from: data)
            try Task.checkCancellation()
            return value
        } catch is DecodingError {
            try remove(scope: scope, key: key)
            return nil
        }
    }

    func save<Value: Encodable & Sendable>(_ value: Value, scope: String, key: String) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(value)
        try Task.checkCancellation()
        let database = try database()
        try execute("BEGIN IMMEDIATE", database: database)
        var committed = false
        defer { if !committed { try? execute("ROLLBACK", database: database) } }

        let update = try statement("""
            INSERT INTO pageContent (scope, cacheKey, payload, updatedAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(scope, cacheKey) DO UPDATE SET
                payload = excluded.payload, updatedAt = excluded.updatedAt
            """, database: database)
        defer { sqlite3_finalize(update) }
        try bind(scope, at: 1, to: update, database: database)
        try bind(key, at: 2, to: update, database: database)
        let blobStatus = data.withUnsafeBytes {
            sqlite3_bind_blob(update, 3, $0.baseAddress, Int32($0.count), transient)
        }
        try check(blobStatus, database: database)
        try check(sqlite3_bind_double(update, 4, Date().timeIntervalSince1970), database: database)
        try finish(update, database: database)

        let trim = try statement("""
            DELETE FROM pageContent WHERE rowid NOT IN (
                SELECT rowid FROM pageContent ORDER BY updatedAt DESC, rowid DESC LIMIT ?
            )
            """, database: database)
        defer { sqlite3_finalize(trim) }
        try check(sqlite3_bind_int(trim, 1, Int32(capacity)), database: database)
        try finish(trim, database: database)
        try Task.checkCancellation()
        try execute("COMMIT", database: database)
        committed = true
    }

    func entries<Value: Decodable & Sendable>(_ type: Value.Type, scope: String, prefix: String) throws -> [String: Value] {
        try Task.checkCancellation()
        let database = try database()
        let query = try statement("""
            SELECT cacheKey, payload FROM pageContent
            WHERE scope = ? AND substr(cacheKey, 1, length(?)) = ?
            """, database: database)
        defer { sqlite3_finalize(query) }
        try bind(scope, at: 1, to: query, database: database)
        try bind(prefix, at: 2, to: query, database: database)
        try bind(prefix, at: 3, to: query, database: database)
        var values: [String: Value] = [:]
        var invalidKeys: [String] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let keyBytes = sqlite3_column_text(query, 0) else {
                throw failure(database, code: status)
            }
            let key = String(cString: keyBytes)
            do { values[key] = try JSONDecoder().decode(type, from: payload(query, column: 1)) }
            catch is DecodingError { invalidKeys.append(key) }
        }
        try Task.checkCancellation()
        for key in invalidKeys { try remove(scope: scope, key: key) }
        return values
    }

    func remove(scope: String, key: String) throws {
        try Task.checkCancellation()
        let database = try database()
        let deletion = try statement("DELETE FROM pageContent WHERE scope = ? AND cacheKey = ?", database: database)
        defer { sqlite3_finalize(deletion) }
        try bind(scope, at: 1, to: deletion, database: database)
        try bind(key, at: 2, to: deletion, database: database)
        try finish(deletion, database: database)
    }

    func removeAll(scope: String) throws {
        try Task.checkCancellation()
        let database = try database()
        let deletion = try statement("DELETE FROM pageContent WHERE scope = ?", database: database)
        defer { sqlite3_finalize(deletion) }
        try bind(scope, at: 1, to: deletion, database: database)
        try finish(deletion, database: database)
    }

    private func database() throws -> OpaquePointer {
        if let connection { return connection.handle }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(directory.appendingPathComponent("content.sqlite").path, &handle,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let error = failure(handle, code: status)
            sqlite3_close_v2(handle)
            throw error
        }
        let opened = Connection(handle: handle)
        try check(sqlite3_busy_timeout(handle, 1_000), database: handle)
        try execute("""
            CREATE TABLE IF NOT EXISTS pageContent (
                scope TEXT NOT NULL,
                cacheKey TEXT NOT NULL,
                payload BLOB NOT NULL,
                updatedAt DOUBLE NOT NULL,
                PRIMARY KEY (scope, cacheKey)
            )
            """, database: handle)
        connection = opened
        return handle
    }

    private func statement(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var result: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &result, nil)
        guard status == SQLITE_OK, let result else {
            sqlite3_finalize(result)
            throw failure(database, code: status)
        }
        return result
    }

    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer, database: OpaquePointer) throws {
        try check(sqlite3_bind_text(statement, index, value, -1, transient), database: database)
    }

    private func payload(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func finish(_ statement: OpaquePointer, database: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw failure(database, code: status) }
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        let query = try statement(sql, database: database)
        defer { sqlite3_finalize(query) }
        try finish(query, database: database)
    }

    private func check(_ status: Int32, database: OpaquePointer) throws {
        guard status == SQLITE_OK else { throw failure(database, code: status) }
    }

    private func failure(_ database: OpaquePointer?, code: Int32) -> CacheError {
        CacheError(code: code, message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open cache")
    }

    private struct CacheError: LocalizedError {
        let code: Int32
        let message: String
        var errorDescription: String? { "页面缓存读写失败（\(code)）：\(message)" }
    }

    /// The handle stays within the owning actor; destruction closes it without an actor hop.
    private final class Connection {
        let handle: OpaquePointer
        init(handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close_v2(handle) }
    }
}
