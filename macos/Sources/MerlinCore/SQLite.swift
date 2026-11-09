import Foundation
import SQLite3

/// A small, thread-safe wrapper over the system SQLite: statements are
/// prepared, bound, stepped and finalized in one call.
final class SQLite: @unchecked Sendable {
  enum Value: Equatable {
    case null, int(Int), real(Double), text(String)
  }

  typealias Row = [String: Value]

  private var db: OpaquePointer?
  private let lock = NSRecursiveLock()
  let url: URL

  init(url: URL) throws {
    self.url = url
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      sqlite3_close(db)
      throw MerlinError("can't open \(url.lastPathComponent): \(message)")
    }
    sqlite3_busy_timeout(db, 3000)
    try exec("PRAGMA foreign_keys = ON")
  }

  deinit { sqlite3_close(db) }

  private var lastError: String { String(cString: sqlite3_errmsg(db)) }

  /// Several statements, no parameters.
  func exec(_ sql: String) throws {
    try lock.withLock {
      guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MerlinError("database: \(lastError)") }
    }
  }

  @discardableResult
  func run(_ sql: String, _ params: [Any?] = []) throws -> Int {
    try lock.withLock {
      _ = try query(sql, params)
      return Int(sqlite3_changes(db))
    }
  }

  func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
    try lock.withLock {
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw MerlinError("database: \(lastError)") }
      defer { sqlite3_finalize(stmt) }
      for (i, p) in params.enumerated() { try bind(stmt, Int32(i + 1), p) }
      var rows: [Row] = []
      while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { break }
        guard rc == SQLITE_ROW else { throw MerlinError("database: \(lastError)") }
        var row: Row = [:]
        for c in 0..<sqlite3_column_count(stmt) {
          let name = String(cString: sqlite3_column_name(stmt, c))
          switch sqlite3_column_type(stmt, c) {
          case SQLITE_INTEGER: row[name] = .int(Int(sqlite3_column_int64(stmt, c)))
          case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
          case SQLITE_NULL: row[name] = .null
          default: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
          }
        }
        rows.append(row)
      }
      return rows
    }
  }

  /// Runs body in a transaction (nested calls join the outer one).
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock {
      if sqlite3_get_autocommit(db) == 0 { return try body() }
      try exec("BEGIN IMMEDIATE")
      do {
        let value = try body()
        try exec("COMMIT")
        return value
      } catch {
        try? exec("ROLLBACK")
        throw error
      }
    }
  }

  var userVersion: Int {
    get { (try? query("PRAGMA user_version"))?.first?["user_version"]?.int ?? 0 }
    set { try? exec("PRAGMA user_version = \(newValue)") }
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ value: Any?) throws {
    let rc: Int32
    switch value {
    case nil, is NSNull: rc = sqlite3_bind_null(stmt, i)
    case let v as Int: rc = sqlite3_bind_int64(stmt, i, Int64(v))
    case let v as Int64: rc = sqlite3_bind_int64(stmt, i, v)
    case let v as Bool: rc = sqlite3_bind_int64(stmt, i, v ? 1 : 0)
    case let v as Double: rc = sqlite3_bind_double(stmt, i, v)
    case let v as String: rc = sqlite3_bind_text(stmt, i, v, -1, Self.transient)
    default: throw MerlinError("database: can't bind \(type(of: value!))")
    }
    guard rc == SQLITE_OK else { throw MerlinError("database: \(lastError)") }
  }
}

extension SQLite.Value {
  var int: Int? {
    switch self {
    case .int(let v): return v
    case .real(let v): return Int(v)
    case .text(let s): return Int(s)
    case .null: return nil
    }
  }

  var string: String? {
    switch self {
    case .text(let s): return s
    case .int(let v): return String(v)
    case .real(let v): return String(v)
    case .null: return nil
    }
  }
}
