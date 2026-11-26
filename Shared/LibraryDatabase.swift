import Foundation
import SQLite3

struct LibraryDatabase {
    static let filename = "Library.sqlite"
    private let handle: OpaquePointer

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtection])
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw DatabaseError.open
        }
        handle = connection
    }

    func close() { sqlite3_close(handle) }

    func read() throws -> LibrarySnapshot? {
        try execute("CREATE TABLE IF NOT EXISTS cards (contents BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS usage (contents BLOB NOT NULL)")
        let cardsData = try readBlob("SELECT contents FROM cards WHERE rowid = 1")
        let usageData = try readBlob("SELECT contents FROM usage WHERE rowid = 1")
        if cardsData == nil && usageData == nil { return nil }
        guard let cardsData, let usageData else { throw DatabaseError.incomplete }
        let decoder = JSONDecoder()
        return try LibrarySnapshot(cards: decoder.decode([Card].self, from: cardsData),
                                   usage: decoder.decode(Usage.self, from: usageData))
    }

    func write(_ value: LibrarySnapshot) throws {
        let encoder = JSONEncoder()
        let cards = try encoder.encode(value.cards)
        let usage = try encoder.encode(value.usage)
        try execute("PRAGMA secure_delete = ON")
        try execute("BEGIN IMMEDIATE")
        do {
            try writeBlob(cards, sql: "INSERT OR REPLACE INTO cards (rowid, contents) VALUES (1, ?)")
            try writeBlob(usage, sql: "INSERT OR REPLACE INTO usage (rowid, contents) VALUES (1, ?)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.statement }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.statement
        }
        return statement
    }

    private func readBlob(_ sql: String) throws -> Data? {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw DatabaseError.incomplete }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        default:
            throw DatabaseError.statement
        }
    }

    private func writeBlob(_ data: Data, sql: String) throws {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { buffer -> Int32 in
            guard let count = Int32(exactly: buffer.count) else { return SQLITE_TOOBIG }
            let status = sqlite3_bind_blob(statement, 1, buffer.baseAddress, count, nil)
            let result = status == SQLITE_OK ? sqlite3_step(statement) : status
            sqlite3_clear_bindings(statement)
            return result
        }
        guard result == SQLITE_DONE else { throw DatabaseError.statement }
    }

    private enum DatabaseError: Error { case open, statement, incomplete }
}
