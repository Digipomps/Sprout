import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

public enum SQLiteBootstrapCacheError: Error {
    case openDatabase(String)
    case prepareStatement(String)
    case execute(String)
}

public actor SQLiteBootstrapCache {
    private let databaseURL: URL
#if canImport(SQLite3)
    private var db: OpaquePointer?
#else
    private var fallback = [String: (data: Data, expiresAt: Date?)]()
#endif

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func put(key: String, value: Data, expiresAt: Date? = nil) throws {
#if canImport(SQLite3)
        try openIfNeeded()
        let sql = "INSERT INTO bootstrap_cache(cache_key, payload, expires_at) VALUES(?, ?, ?) ON CONFLICT(cache_key) DO UPDATE SET payload = excluded.payload, expires_at = excluded.expires_at;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteBootstrapCacheError.prepareStatement(lastError())
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        _ = value.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
        }
        if let expiresAt {
            sqlite3_bind_double(statement, 3, expiresAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 3)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteBootstrapCacheError.execute(lastError())
        }
#else
        fallback[key] = (value, expiresAt)
#endif
    }

    public func get(key: String, now: Date = Date()) throws -> Data? {
#if canImport(SQLite3)
        try openIfNeeded()
        let sql = "SELECT payload, expires_at FROM bootstrap_cache WHERE cache_key = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteBootstrapCacheError.prepareStatement(lastError())
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let expiresType = sqlite3_column_type(statement, 1)
        if expiresType != SQLITE_NULL {
            let expiry = sqlite3_column_double(statement, 1)
            if now.timeIntervalSince1970 > expiry {
                try delete(key: key)
                return nil
            }
        }

        guard let bytes = sqlite3_column_blob(statement, 0) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return Data(bytes: bytes, count: count)
#else
        guard let entry = fallback[key] else { return nil }
        if let expiresAt = entry.expiresAt, now > expiresAt {
            fallback[key] = nil
            return nil
        }
        return entry.data
#endif
    }

    public func delete(key: String) throws {
#if canImport(SQLite3)
        try openIfNeeded()
        let sql = "DELETE FROM bootstrap_cache WHERE cache_key = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteBootstrapCacheError.prepareStatement(lastError())
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteBootstrapCacheError.execute(lastError())
        }
#else
        fallback[key] = nil
#endif
    }

#if canImport(SQLite3)
    private func openIfNeeded() throws {
        if db != nil {
            return
        }

        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw SQLiteBootstrapCacheError.openDatabase(lastError())
        }

        let createSQL = """
        CREATE TABLE IF NOT EXISTS bootstrap_cache (
            cache_key TEXT PRIMARY KEY,
            payload BLOB NOT NULL,
            expires_at REAL NULL
        );
        """

        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteBootstrapCacheError.execute(lastError())
        }
    }

    private func lastError() -> String {
        if let db, let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }
        return "unknown_sqlite_error"
    }
#endif
}

#if canImport(SQLite3)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif
