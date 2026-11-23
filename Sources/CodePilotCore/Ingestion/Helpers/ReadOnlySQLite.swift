import Foundation
import SQLite3

public enum ReadOnlySQLiteError: Error, Sendable {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
}

public enum SQLiteValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    public var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }
}

/// Safe short-lived read-only SQLite helper for WAL databases.
/// Never uses `immutable=1` on live WAL files and never holds persistent connections.
public struct ReadOnlySQLite: Sendable {
    public let path: String
    public let busyTimeoutMs: Int32

    public init(path: String, busyTimeoutMs: Int32 = 200) {
        self.path = path
        self.busyTimeoutMs = max(50, busyTimeoutMs)
    }

    /// Executes a read-only query using a short-lived connection.
    /// Falls back to a temporary snapshot copy (.db + -wal + -shm) if direct WAL read hits lock/permission issues.
    public func query(_ sql: String) throws -> [[String: SQLiteValue]] {
        do {
            return try runDirectQuery(at: path, sql: sql)
        } catch let err as ReadOnlySQLiteError {
            if case .openFailed = err {
                return try runSnapshotQuery(sql: sql)
            }
            if case .stepFailed(let code, _) = err, code == SQLITE_BUSY || code == SQLITE_LOCKED || code == SQLITE_READONLY {
                return try runSnapshotQuery(sql: sql)
            }
            throw err
        }
    }

    private func runDirectQuery(at dbPath: String, sql: String) throws -> [[String: SQLiteValue]] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let openRC = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard openRC == SQLITE_OK, let handle = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open_failed"
            if let db { sqlite3_close(db) }
            throw ReadOnlySQLiteError.openFailed(code: openRC, message: msg)
        }
        defer { sqlite3_close(handle) }

        _ = sqlite3_busy_timeout(handle, busyTimeoutMs)
        _ = sqlite3_exec(handle, "PRAGMA query_only = ON;", nil, nil, nil)

        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepRC == SQLITE_OK, let statement = stmt else {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw ReadOnlySQLiteError.prepareFailed(code: prepRC, message: msg)
        }
        defer { sqlite3_finalize(statement) }

        let colCount = sqlite3_column_count(statement)
        var colNames: [String] = []
        colNames.reserveCapacity(Int(colCount))
        for i in 0..<colCount {
            if let namePtr = sqlite3_column_name(statement, i) {
                colNames.append(String(cString: namePtr))
            } else {
                colNames.append("col_\(i)")
            }
        }

        var rows: [[String: SQLiteValue]] = []
        while true {
            let stepRC = sqlite3_step(statement)
            if stepRC == SQLITE_ROW {
                var row: [String: SQLiteValue] = [:]
                for i in 0..<colCount {
                    let colType = sqlite3_column_type(statement, i)
                    let value: SQLiteValue
                    switch colType {
                    case SQLITE_INTEGER:
                        value = .int(sqlite3_column_int64(statement, i))
                    case SQLITE_FLOAT:
                        value = .double(sqlite3_column_double(statement, i))
                    case SQLITE_TEXT:
                        if let ptr = sqlite3_column_text(statement, i) {
                            value = .text(String(cString: ptr))
                        } else {
                            value = .null
                        }
                    default:
                        value = .null
                    }
                    row[colNames[Int(i)]] = value
                }
                rows.append(row)
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(handle))
                throw ReadOnlySQLiteError.stepFailed(code: stepRC, message: msg)
            }
        }
        return rows
    }

    private func runSnapshotQuery(sql: String) throws -> [[String: SQLiteValue]] {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("cp-sqlite-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let baseName = URL(fileURLWithPath: path).lastPathComponent
        let dstDB = tempDir.appendingPathComponent(baseName).path
        try fm.copyItem(atPath: path, toPath: dstDB)

        for suffix in ["-wal", "-shm"] {
            let src = path + suffix
            if fm.fileExists(atPath: src) {
                try? fm.copyItem(atPath: src, toPath: dstDB + suffix)
            }
        }

        return try runDirectQuery(at: dstDB, sql: sql)
    }
}
