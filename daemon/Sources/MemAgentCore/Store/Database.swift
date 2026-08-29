import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case exec(String, String)

    public var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .exec(let sql, let m): return "sqlite error: \(m) in [\(sql.prefix(80))]"
        }
    }
}

/// Minimal single-writer SQLite wrapper (WAL). Not thread-safe on its own —
/// the daemon serializes access through its queue.
public final class Database {
    private var db: OpaquePointer?

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS system_samples(
            ts REAL NOT NULL,
            total INTEGER, free INTEGER, active INTEGER, inactive INTEGER,
            wired INTEGER, compressed INTEGER, purgeable INTEGER,
            swap_total INTEGER, swap_used INTEGER,
            swap_ins INTEGER, swap_outs INTEGER,
            page_ins INTEGER, page_outs INTEGER,
            pressure_level INTEGER, avail INTEGER)
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_system_ts ON system_samples(ts)")
        try exec("""
        CREATE TABLE IF NOT EXISTS process_samples(
            ts REAL NOT NULL, pid INTEGER NOT NULL, name TEXT NOT NULL,
            footprint INTEGER, resident INTEGER, cpu_time INTEGER, source TEXT)
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_process_ts ON process_samples(ts)")
        try exec("CREATE INDEX IF NOT EXISTS idx_process_pid ON process_samples(pid, ts)")
        try exec("""
        CREATE TABLE IF NOT EXISTS events(
            ts REAL NOT NULL, kind TEXT NOT NULL, json TEXT NOT NULL)
        """)
        // v0.3 additions.
        try exec("""
        CREATE TABLE IF NOT EXISTS state_blobs(
            key TEXT PRIMARY KEY, json TEXT NOT NULL, updated REAL)
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS app_usage(
            ts REAL NOT NULL, name TEXT NOT NULL, event TEXT NOT NULL)
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_usage_ts ON app_usage(ts)")
        try exec("""
        CREATE TABLE IF NOT EXISTS action_log(
            ts REAL NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL,
            pid INTEGER, refault INTEGER DEFAULT 0)
        """)
    }

    // MARK: - State blobs (persisted model state: histograms, usage model)

    public func saveBlob(key: String, json: String) throws {
        try withStatement("""
            INSERT INTO state_blobs(key, json, updated) VALUES(?,?,?)
            ON CONFLICT(key) DO UPDATE SET json=excluded.json, updated=excluded.updated
            """) { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, json, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        }
    }

    public func loadBlob(key: String) throws -> String? {
        var result: String?
        try query("SELECT json FROM state_blobs WHERE key = ?",
                  bind: { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }) { stmt in
            result = String(cString: sqlite3_column_text(stmt, 0))
        }
        return result
    }

    // MARK: - Usage + action log (Stage D)

    public func insertUsage(ts: Double, name: String, event: String) throws {
        try withStatement("INSERT INTO app_usage(ts,name,event) VALUES(?,?,?)") { stmt in
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, event, -1, SQLITE_TRANSIENT)
        }
    }

    public func insertAction(ts: Double, action: String, target: String, pid: Int32) throws {
        try withStatement("INSERT INTO action_log(ts,action,target,pid) VALUES(?,?,?,?)") { stmt in
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, action, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, target, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(pid))
        }
    }

    public func markRefault(action: String, target: String, since: Double) throws {
        try withStatement("""
            UPDATE action_log SET refault = 1
            WHERE action = ? AND target = ? AND ts >= ? AND refault = 0
            """) { stmt in
            sqlite3_bind_text(stmt, 1, action, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, target, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, since)
        }
    }

    /// (executed, refaulted) counts per action type over the trailing window.
    public func actionStats(action: String, sinceDays: Double) throws -> (total: Int, refaults: Int) {
        var total = 0, refaults = 0
        let since = Date().timeIntervalSince1970 - sinceDays * 86400
        try query("""
            SELECT COUNT(*), COALESCE(SUM(refault),0) FROM action_log
            WHERE action = ? AND ts >= ?
            """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, action, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, since)
        }) { stmt in
            total = Int(sqlite3_column_int64(stmt, 0))
            refaults = Int(sqlite3_column_int64(stmt, 1))
        }
        return (total, refaults)
    }

    /// Full system-sample series for backtesting: (ts, avail, pressure_level).
    public func systemSeries(since: Double) throws -> [(t: Double, avail: Double, level: Int)] {
        var out: [(Double, Double, Int)] = []
        try query("SELECT ts, avail, pressure_level FROM system_samples WHERE ts >= ? ORDER BY ts",
                  bind: { sqlite3_bind_double($0, 1, since) }) { stmt in
            out.append((sqlite3_column_double(stmt, 0),
                        Double(sqlite3_column_int64(stmt, 1)),
                        Int(sqlite3_column_int64(stmt, 2))))
        }
        return out
    }

    public func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DatabaseError.exec(sql, msg)
        }
    }

    // MARK: - Inserts

    public func insert(system s: SystemSnapshot) throws {
        let sql = """
        INSERT INTO system_samples
        (ts,total,free,active,inactive,wired,compressed,purgeable,swap_total,swap_used,
         swap_ins,swap_outs,page_ins,page_outs,pressure_level,avail)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        try withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, s.ts)
            let ints: [UInt64] = [s.totalBytes, s.freeBytes, s.activeBytes, s.inactiveBytes,
                                  s.wiredBytes, s.compressedBytes, s.purgeableBytes,
                                  s.swapTotalBytes, s.swapUsedBytes, s.swapIns, s.swapOuts,
                                  s.pageIns, s.pageOuts]
            for (i, v) in ints.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 2), Int64(bitPattern: v))
            }
            sqlite3_bind_int64(stmt, 15, Int64(s.pressureLevel))
            sqlite3_bind_int64(stmt, 16, Int64(bitPattern: s.availBytes))
        }
    }

    public func insert(processes: [ProcessSample]) throws {
        try exec("BEGIN")
        defer { try? exec("COMMIT") }
        let sql = "INSERT INTO process_samples(ts,pid,name,footprint,resident,cpu_time,source) VALUES(?,?,?,?,?,?,?)"
        for p in processes {
            try withStatement(sql) { stmt in
                sqlite3_bind_double(stmt, 1, p.ts)
                sqlite3_bind_int64(stmt, 2, Int64(p.pid))
                sqlite3_bind_text(stmt, 3, p.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 4, Int64(bitPattern: p.footprintBytes))
                sqlite3_bind_int64(stmt, 5, Int64(bitPattern: p.residentBytes))
                sqlite3_bind_int64(stmt, 6, Int64(bitPattern: p.cpuTime))
                sqlite3_bind_text(stmt, 7, p.source, -1, SQLITE_TRANSIENT)
            }
        }
    }

    public func insertEvent(kind: String, json: String, at ts: Double = Date().timeIntervalSince1970) throws {
        try withStatement("INSERT INTO events(ts,kind,json) VALUES(?,?,?)") { stmt in
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, kind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, json, -1, SQLITE_TRANSIENT)
        }
    }

    // MARK: - Queries

    public func systemAvailSeries(since: Double) throws -> [(t: Double, avail: Double)] {
        var out: [(Double, Double)] = []
        try query("SELECT ts, avail FROM system_samples WHERE ts >= ? ORDER BY ts",
                  bind: { sqlite3_bind_double($0, 1, since) }) { stmt in
            out.append((sqlite3_column_double(stmt, 0), Double(sqlite3_column_int64(stmt, 1))))
        }
        return out
    }

    public func processHistory(pid: Int32, since: Double) throws -> [ProcessSample] {
        var out: [ProcessSample] = []
        try query("""
            SELECT ts, pid, name, footprint, resident, cpu_time, source
            FROM process_samples WHERE pid = ? AND ts >= ? ORDER BY ts
            """,
            bind: { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(pid))
                sqlite3_bind_double(stmt, 2, since)
            }) { stmt in
            out.append(ProcessSample(
                ts: sqlite3_column_double(stmt, 0),
                pid: Int32(sqlite3_column_int64(stmt, 1)),
                name: String(cString: sqlite3_column_text(stmt, 2)),
                footprintBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 3)),
                residentBytes: UInt64(bitPattern: sqlite3_column_int64(stmt, 4)),
                cpuTime: UInt64(bitPattern: sqlite3_column_int64(stmt, 5)),
                source: String(cString: sqlite3_column_text(stmt, 6))))
        }
        return out
    }

    /// Delete rows older than `days` and downsample nothing (v1 keeps it simple).
    public func prune(olderThanDays days: Double) throws {
        let cutoff = Date().timeIntervalSince1970 - days * 86400
        for table in ["system_samples", "process_samples", "events"] {
            try withStatement("DELETE FROM \(table) WHERE ts < ?") { stmt in
                sqlite3_bind_double(stmt, 1, cutoff)
            }
        }
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: - Statement plumbing

    private func withStatement(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.exec(sql, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.exec(sql, String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String,
                       bind: (OpaquePointer) -> Void = { _ in },
                       row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.exec(sql, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt)
        }
    }
}
