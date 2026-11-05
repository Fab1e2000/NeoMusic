import Foundation
import SQLite3

/// Complete collection membership lives outside the evictable page cache.
/// All decoding, matching and SQLite work runs on this actor.
actor NeteaseLibrarySearchIndex {
    struct Session: Sendable, Equatable {
        let owner: String
        let revision: UUID
    }
    private let directory: URL
    private var active: Session?
    init(directory: URL) { self.directory = directory }
    func activate(_ session: Session?) { active = session }

    func versions(session: Session) throws -> [String: String] {
        try validate(session)
        let db = try open(); defer { sqlite3_close(db) }
        let statement = try prepare("SELECT collection, version FROM collections WHERE owner = ?", db)
        defer { sqlite3_finalize(statement) }
        try bind(session.owner, to: 1, statement, db)
        var result: [String: String] = [:]
        while try step(statement, db) { result[string(statement, 0)] = string(statement, 1) }
        return result
    }

    func replace(collection: String, version: String, resources: [NeteaseSearchResource], session: Session) throws {
        try validate(session)
        let db = try open(); defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db)
        var committed = false
        defer { if !committed { try? execute("ROLLBACK", db) } }
        try deleteMembers(collection: collection, session: session, db)
        let item = try prepare("INSERT INTO items(owner, id, kind, title, searchText, payload) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(owner, id) DO UPDATE SET kind=excluded.kind, title=excluded.title, searchText=excluded.searchText, payload=excluded.payload", db)
        let member = try prepare("INSERT OR IGNORE INTO members(owner, collection, item) VALUES(?, ?, ?)", db)
        defer { sqlite3_finalize(item); sqlite3_finalize(member) }
        var seen = Set<String>()
        for resource in resources where seen.insert(resource.id).inserted {
            try validate(session)
            let payload = String(decoding: try JSONEncoder().encode(resource), as: UTF8.self)
            let fields = [session.owner, resource.id, String(resource.kind.rawValue), Self.normalized(resource.title),
                          Self.normalized([resource.title, resource.subtitle, resource.song?.album ?? ""].joined(separator: "\n")), payload]
            for (index, value) in fields.enumerated() { try bind(value, to: Int32(index + 1), item, db) }
            _ = try step(item, db); sqlite3_reset(item); sqlite3_clear_bindings(item)
            for (index, value) in [session.owner, collection, resource.id].enumerated() { try bind(value, to: Int32(index + 1), member, db) }
            _ = try step(member, db); sqlite3_reset(member); sqlite3_clear_bindings(member)
        }
        let update = try prepare("INSERT INTO collections(owner, collection, version) VALUES(?, ?, ?) ON CONFLICT(owner, collection) DO UPDATE SET version=excluded.version", db)
        defer { sqlite3_finalize(update) }
        for (index, value) in [session.owner, collection, version].enumerated() { try bind(value, to: Int32(index + 1), update, db) }
        _ = try step(update, db)
        try removeOrphans(session, db)
        try validate(session)
        try execute("COMMIT", db); committed = true
    }

    /// Call only after a successful collection-directory response for this prefix.
    func reconcile(prefix: String, keeping: Set<String>, session: Session) throws {
        let old = try versions(session: session).keys.filter { $0.hasPrefix(prefix) && !keeping.contains($0) }
        guard !old.isEmpty else { return }
        let db = try open(); defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db)
        var committed = false
        defer { if !committed { try? execute("ROLLBACK", db) } }
        let statement = try prepare("DELETE FROM collections WHERE owner = ? AND collection = ?", db)
        defer { sqlite3_finalize(statement) }
        for collection in old {
            try validate(session)
            try deleteMembers(collection: collection, session: session, db)
            try bind(session.owner, to: 1, statement, db); try bind(collection, to: 2, statement, db)
            _ = try step(statement, db); sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        }
        try removeOrphans(session, db)
        try validate(session)
        try execute("COMMIT", db); committed = true
    }

    func search(_ query: String, kind: NeteaseSearchKind = .combined, session: Session) throws -> [NeteaseSearchResource] {
        try validate(session)
        let term = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !term.isEmpty else { return [] }
        let db = try open(); defer { sqlite3_close(db) }
        let statement = try prepare("SELECT payload FROM items WHERE owner = ? AND (? = '1018' OR kind = ?) AND instr(searchText, ?) > 0 ORDER BY CASE WHEN title = ? THEN 0 WHEN instr(title, ?) = 1 THEN 1 ELSE 2 END, title, id", db)
        defer { sqlite3_finalize(statement) }
        let values = [session.owner, String(kind.rawValue), String(kind.rawValue), term, term, term]
        for (index, value) in values.enumerated() { try bind(value, to: Int32(index + 1), statement, db) }
        var result: [NeteaseSearchResource] = []
        while try step(statement, db) {
            try validate(session)
            result.append(try JSONDecoder().decode(NeteaseSearchResource.self, from: Data(string(statement, 0).utf8)))
        }
        return result
    }

    func songs(session: Session) throws -> [Int64: NeteaseMusicSong] {
        try validate(session)
        let db = try open(); defer { sqlite3_close(db) }
        let statement = try prepare("SELECT payload FROM items WHERE owner = ? AND kind = 1", db)
        defer { sqlite3_finalize(statement) }
        try bind(session.owner, to: 1, statement, db)
        var result: [Int64: NeteaseMusicSong] = [:]
        while try step(statement, db) {
            try validate(session)
            let resource = try JSONDecoder().decode(NeteaseSearchResource.self, from: Data(string(statement, 0).utf8))
            if let song = resource.song { result[song.id] = song }
        }
        return result
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans_CN"))
    }
    private func validate(_ session: Session) throws {
        try Task.checkCancellation()
        guard active == session else { throw CancellationError() }
    }
    private func open() throws -> OpaquePointer {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(directory.appendingPathComponent("library-search.sqlite").path, &handle,
                                   SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let db = handle else { if let handle { sqlite3_close(handle) }; throw CocoaError(.fileReadUnknown) }
        do {
            try execute("CREATE TABLE IF NOT EXISTS items(owner TEXT NOT NULL, id TEXT NOT NULL, kind INTEGER NOT NULL, title TEXT NOT NULL, searchText TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(owner,id)); CREATE TABLE IF NOT EXISTS members(owner TEXT NOT NULL, collection TEXT NOT NULL, item TEXT NOT NULL, PRIMARY KEY(owner,collection,item)); CREATE TABLE IF NOT EXISTS collections(owner TEXT NOT NULL, collection TEXT NOT NULL, version TEXT NOT NULL, PRIMARY KEY(owner,collection)); CREATE INDEX IF NOT EXISTS member_item ON members(owner,item)", db)
            return db
        } catch { sqlite3_close(db); throw error }
    }
    private func deleteMembers(collection: String, session: Session, _ db: OpaquePointer) throws {
        let statement = try prepare("DELETE FROM members WHERE owner = ? AND collection = ?", db)
        defer { sqlite3_finalize(statement) }
        try bind(session.owner, to: 1, statement, db); try bind(collection, to: 2, statement, db)
        _ = try step(statement, db)
    }
    private func removeOrphans(_ session: Session, _ db: OpaquePointer) throws {
        let statement = try prepare("DELETE FROM items WHERE owner = ? AND NOT EXISTS(SELECT 1 FROM members WHERE members.owner=items.owner AND members.item=items.id)", db)
        defer { sqlite3_finalize(statement) }
        try bind(session.owner, to: 1, statement, db); _ = try step(statement, db)
    }
    private func execute(_ sql: String, _ db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    private func prepare(_ sql: String, _ db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(db) }
        return statement
    }
    private func bind(_ text: String, to index: Int32, _ statement: OpaquePointer, _ db: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw failure(db) }
    }
    private func step(_ statement: OpaquePointer, _ db: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure(db) }
        return result == SQLITE_ROW
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String { String(cString: sqlite3_column_text(statement, column)) }
    private func failure(_ db: OpaquePointer) -> NSError {
        NSError(domain: "NeoMusic.SearchIndex", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: "资料库搜索索引暂时无法读写。"])
    }
}
