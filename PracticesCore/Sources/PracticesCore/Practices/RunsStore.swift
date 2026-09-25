import Foundation
import SQLite3

/// One run of a practice, as kept in `runs.sqlite`: timing, size, shape and schema — never
/// the data itself (a sandbox run of a prod query must not leave a copy of it on disk).
public struct RunRecord: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    public let ref: String
    public let version: Int?
    public let env: String
    public let params: String
    public let started: Date
    public let millis: Int
    public let ok: Bool
    public let rows: Int?
    public let bytes: Int?
    public let error: String?
    public let schema: String?
    public let steps: String?
}

public final class RunsStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL = PracticesHome.url.appendingPathComponent("runs.sqlite")) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure(message: "cannot open \(url.path)") }
        try exec("""
            CREATE TABLE IF NOT EXISTS runs (
              id INTEGER PRIMARY KEY, ref TEXT NOT NULL, version INTEGER, env TEXT NOT NULL,
              params TEXT NOT NULL, started REAL NOT NULL, ms INTEGER NOT NULL, ok INTEGER NOT NULL,
              rows INTEGER, bytes INTEGER, error TEXT, schema TEXT, steps TEXT);
            CREATE INDEX IF NOT EXISTS runs_ref ON runs(ref, started);
            """)
    }

    deinit { sqlite3_close(db) }

    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    public func insert(ref: String, version: Int?, env: String, params: String, started: Date, millis: Int,
                       ok: Bool, rows: Int?, bytes: Int?, error: String?, schema: String?, steps: String?) throws -> Int64 {
        try lock.withLock {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO runs (ref, version, env, params, started, ms, ok, rows, bytes, error, schema, steps) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(stmt) }
            func text(_ i: Int32, _ s: String?) { if let s { sqlite3_bind_text(stmt, i, s, -1, Self.transient) } else { sqlite3_bind_null(stmt, i) } }
            func int(_ i: Int32, _ v: Int?) { if let v { sqlite3_bind_int64(stmt, i, Int64(v)) } else { sqlite3_bind_null(stmt, i) } }
            text(1, ref); int(2, version); text(3, env); text(4, params)
            sqlite3_bind_double(stmt, 5, started.timeIntervalSince1970)
            int(6, millis); int(7, ok ? 1 : 0); int(8, rows); int(9, bytes)
            text(10, error); text(11, schema); text(12, steps)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func runs(of ref: String, limit: Int = 200) -> [RunRecord] {
        query("SELECT id, ref, version, env, params, started, ms, ok, rows, bytes, error, schema, steps FROM runs WHERE ref = ? ORDER BY started DESC LIMIT \(limit)", ref)
    }

    public func recent(limit: Int = 200) -> [RunRecord] {
        query("SELECT id, ref, version, env, params, started, ms, ok, rows, bytes, error, schema, steps FROM runs ORDER BY started DESC LIMIT \(limit)", nil)
    }

    /// Latest schema per practice: what search matches field paths against (DECISIONS 24).
    public func latestSchemas() -> [String: String] {
        lock.withLock {
            var stmt: OpaquePointer?
            let sql = "SELECT ref, schema FROM runs r WHERE ok = 1 AND schema IS NOT NULL AND started = (SELECT MAX(started) FROM runs WHERE ref = r.ref AND ok = 1 AND schema IS NOT NULL)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var out: [String: String] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                out[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
            }
            return out
        }
    }

    private func query(_ sql: String, _ arg: String?) -> [RunRecord] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let arg { sqlite3_bind_text(stmt, 1, arg, -1, Self.transient) }
            var out: [RunRecord] = []
            func text(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i)) }
            func int(_ i: Int32) -> Int? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i)) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(RunRecord(
                    id: sqlite3_column_int64(stmt, 0), ref: text(1) ?? "", version: int(2), env: text(3) ?? "",
                    params: text(4) ?? "{}", started: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    millis: int(6) ?? 0, ok: int(7) == 1, rows: int(8), bytes: int(9), error: text(10),
                    schema: text(11), steps: text(12)))
            }
            return out
        }
    }
}
