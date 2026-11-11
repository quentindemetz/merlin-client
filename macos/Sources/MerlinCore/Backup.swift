import CryptoKit
import Foundation
import Security

/// Where the library is backed up: an S3 bucket (made by infra/backup).
/// Kept in config.json under "backup"; the secret key is in the Keychain.
public struct BackupSettings: Equatable, Sendable {
  public var bucket = ""
  public var region = "eu-west-1"
  /// Key prefix inside the bucket ("" or "something/").
  public var prefix = ""
  public var accessKeyID = ""
  /// Back up a little after each change to the library.
  public var automatic = true

  public init() {}

  public var isConfigured: Bool { !bucket.isEmpty && !region.isEmpty && !accessKeyID.isEmpty }

  public var normalizedPrefix: String {
    let p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    return p.isEmpty ? "" : p + "/"
  }

  public var location: String { "s3://\(bucket)/\(normalizedPrefix)" }

  public static func load(_ config: Config) -> BackupSettings {
    var s = BackupSettings()
    guard let o = config.settings["backup"] as? JSONObject else { return s }
    s.bucket = o["bucket"] as? String ?? ""
    s.region = o["region"] as? String ?? s.region
    s.prefix = o["prefix"] as? String ?? ""
    s.accessKeyID = o["access_key_id"] as? String ?? ""
    s.automatic = o["automatic"] as? Bool ?? true
    return s
  }

  public func save(_ config: Config) {
    config.saveSettings(["backup": [
      "bucket": bucket.trimmingCharacters(in: .whitespaces), "region": region.trimmingCharacters(in: .whitespaces),
      "prefix": prefix, "access_key_id": accessKeyID.trimmingCharacters(in: .whitespaces), "automatic": automatic,
    ] as JSONObject])
  }
}

/// The secret access key, in the login Keychain (service "Merlin S3 Backup",
/// account: the access key ID).
public enum BackupKeychain {
  public static let service = "Merlin S3 Backup"

  public static func secret(for accessKeyID: String) -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: accessKeyID, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func setSecret(_ secret: String, for accessKeyID: String) throws {
    let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                               kSecAttrAccount as String: accessKeyID]
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecValueData as String] = Data(secret.utf8)
    add[kSecAttrLabel as String] = service
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw MerlinError("couldn't save the secret key in the Keychain (\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"))")
    }
  }
}

/// Backs a library up to an object store and restores it.
///
/// Layout under the prefix: `files/<name>` for every audio file and cover,
/// `Library.sqlite` (a snapshot of the database, written after the files it
/// refers to) and `backup.json` (what the backup holds). Files are compared
/// by size and MD5 (the ETag), so only new or changed files are sent; files
/// the library no longer refers to are deleted once the new database is up
/// (the bucket's versioning keeps them for a while).
public final class LibraryBackup: @unchecked Sendable {
  public struct Progress: Sendable {
    public enum Phase: Sendable { case checking, transferring, finishing }
    public var phase: Phase
    public var filesDone = 0
    public var filesTotal = 0
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0

    public init(phase: Phase, filesDone: Int = 0, filesTotal: Int = 0, bytesDone: Int64 = 0, bytesTotal: Int64 = 0) {
      self.phase = phase
      self.filesDone = filesDone
      self.filesTotal = filesTotal
      self.bytesDone = bytesDone
      self.bytesTotal = bytesTotal
    }
  }

  public struct Manifest: Codable, Sendable, Equatable {
    public var libraryID: String
    public var date: Date
    public var folders: Int
    public var tracks: Int
    public var files: Int
    public var bytes: Int64
  }

  public struct Summary: Sendable {
    /// Files sent (backup) or fetched (restore).
    public var transferred = 0
    public var transferredBytes: Int64 = 0
    public var deleted = 0
    public var files = 0
    public var bytes: Int64 = 0
    /// Files the database refers to but that couldn't be found.
    public var missing: [String] = []
  }

  /// The bucket holds the backup of another library.
  public struct OtherLibrary: LocalizedError {
    public let manifest: Manifest
    public var errorDescription: String? {
      "the bucket holds the backup of another library (\(manifest.tracks) tracks, \(manifest.date.formatted(date: .abbreviated, time: .shortened)))"
    }
  }

  public static let databaseKey = "Library.sqlite"
  public static let manifestKey = "backup.json"

  let store: ObjectStore
  let prefix: String
  let indexDir: URL
  let cancel: CancelToken?
  public var onProgress: ((Progress) -> Void)?

  /// indexDir: where the MD5s of local files are cached between runs.
  public init(store: ObjectStore, prefix: String = "", indexDir: URL, cancel: CancelToken? = nil) {
    self.store = store
    self.prefix = prefix
    self.indexDir = indexDir
    self.cancel = cancel
  }

  var filesPrefix: String { prefix + "files/" }

  // MARK: Backup

  public func backUp(_ library: MediaLibrary, replacingOtherLibrary: Bool = false) throws -> Summary {
    let id = library.libraryID
    if !replacingOtherLibrary, let m = try manifest(), m.libraryID != id { throw OtherLibrary(manifest: m) }
    var progress = Progress(phase: .checking)
    onProgress?(progress)

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-backup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let snapshot = tmp.appendingPathComponent(Self.databaseKey)
    try library.snapshot(to: snapshot)
    let contents = try MediaLibrary.contents(ofDatabase: snapshot)

    let remote = Dictionary(try store.list(prefix: filesPrefix, cancel: cancel).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    var index = Index(url: indexDir.appendingPathComponent("\(id).json"))
    defer { index.save() }
    var summary = Summary()
    var todo: [(name: String, size: Int64, md5: Data)] = []
    progress.filesTotal = contents.files.count
    for name in contents.files {
      try cancel.check()
      let url = library.url(name)
      guard let md5 = try index.md5(url) else {
        summary.missing.append(name)
        continue
      }
      let size = Index.stat(url)?.size ?? 0
      summary.files += 1
      summary.bytes += size
      progress.filesDone += 1
      onProgress?(progress)
      if let r = remote[filesPrefix + name], r.size == size, r.etag == SigV4.hex(md5) { continue }
      todo.append((name, size, md5))
    }

    progress = Progress(phase: .transferring, filesTotal: todo.count, bytesTotal: todo.reduce(0) { $0 + $1.size })
    onProgress?(progress)
    for file in todo {
      try cancel.check()
      let base = progress.bytesDone
      try store.put(library.url(file.name), key: filesPrefix + file.name, md5: file.md5, contentType: Self.contentType(file.name),
                    cancel: cancel) { sent in
        var p = progress
        p.bytesDone = base + min(sent, file.size)
        self.onProgress?(p)
      }
      progress.filesDone += 1
      progress.bytesDone = base + file.size
      summary.transferred += 1
      summary.transferredBytes += file.size
      onProgress?(progress)
    }

    progress.phase = .finishing
    onProgress?(progress)
    try store.put(snapshot, key: prefix + Self.databaseKey, md5: try Index.hash(snapshot), contentType: "application/vnd.sqlite3",
                  cancel: cancel, progress: nil)
    let manifest = Manifest(libraryID: id, date: Date(), folders: contents.folders, tracks: contents.tracks,
                            files: summary.files, bytes: summary.bytes)
    let manifestFile = tmp.appendingPathComponent(Self.manifestKey)
    try Self.encoder.encode(manifest).write(to: manifestFile)
    try store.put(manifestFile, key: prefix + Self.manifestKey, md5: try Index.hash(manifestFile), contentType: "application/json",
                  cancel: cancel, progress: nil)

    // Only now that the new database is up: drop what it no longer refers to.
    let kept = Set(contents.files.map { filesPrefix + $0 })
    for key in remote.keys.sorted() where !kept.contains(key) {
      try cancel.check()
      try store.delete(key, cancel: cancel)
      summary.deleted += 1
    }
    return summary
  }

  /// What the bucket holds, or nil when it holds no backup.
  public func manifest() throws -> Manifest? {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-manifest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
      try store.get(prefix + Self.manifestKey, to: tmp, cancel: cancel, progress: nil)
    } catch let error as S3Error where error.isNotFound {
      return nil
    }
    return try Self.decoder.decode(Manifest.self, from: Data(contentsOf: tmp))
  }

  // MARK: Restore

  /// Restores the backup into root, which must not hold a library yet. Files
  /// already there with the right size are kept (so an interrupted restore
  /// resumes); the database goes in last, so the folder only becomes a
  /// library once everything is in.
  public func restore(into root: URL) throws -> Summary {
    guard !MediaLibrary.exists(at: root) else { throw MerlinError("\(root.lastPathComponent) already holds a library") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var progress = Progress(phase: .checking)
    onProgress?(progress)
    let db = root.appendingPathComponent(".\(UUID().uuidString.lowercased()).sqlite")
    defer { try? FileManager.default.removeItem(at: db) }
    do {
      try store.get(prefix + Self.databaseKey, to: db, cancel: cancel, progress: nil)
    } catch let error as S3Error where error.isNotFound {
      throw MerlinError("there's no backup in this bucket")
    }
    let contents = try MediaLibrary.contents(ofDatabase: db)
    let remote = Dictionary(try store.list(prefix: filesPrefix, cancel: cancel).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    var index = Index(url: indexDir.appendingPathComponent("\(contents.libraryID ?? "unknown").json"))
    defer { index.save() }

    var summary = Summary()
    var todo: [RemoteObject] = []
    for name in contents.files {
      guard let r = remote[filesPrefix + name] else {
        summary.missing.append(name)
        continue
      }
      summary.files += 1
      summary.bytes += r.size
      if Index.stat(root.appendingPathComponent(name))?.size != r.size { todo.append(r) }
    }
    progress = Progress(phase: .transferring, filesTotal: todo.count, bytesTotal: todo.reduce(0) { $0 + $1.size })
    onProgress?(progress)
    for r in todo {
      try cancel.check()
      let name = String(r.key.dropFirst(filesPrefix.count))
      let part = root.appendingPathComponent(".\(UUID().uuidString.lowercased()).part")
      defer { try? FileManager.default.removeItem(at: part) }
      let base = progress.bytesDone
      try store.get(r.key, to: part, cancel: cancel) { received in
        var p = progress
        p.bytesDone = base + min(received, r.size)
        self.onProgress?(p)
      }
      let dest = root.appendingPathComponent(name)
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.moveItem(at: part, to: dest)
      // The next backup needn't hash what it just fetched.
      if let md5 = Data(hex: r.etag) { index.record(dest, md5: md5) }
      progress.filesDone += 1
      progress.bytesDone = base + r.size
      summary.transferred += 1
      summary.transferredBytes += r.size
      onProgress?(progress)
    }
    progress.phase = .finishing
    onProgress?(progress)
    try FileManager.default.moveItem(at: db, to: root.appendingPathComponent(MediaLibrary.databaseName))
    return summary
  }

  // MARK: Helpers

  static func contentType(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "mp3": return "audio/mpeg"
    case "m4a", "aac", "alac": return "audio/mp4"
    case "wav": return "audio/wav"
    case "aif", "aiff": return "audio/aiff"
    case "flac": return "audio/flac"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    default: return "application/octet-stream"
    }
  }

  static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }()

  static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  /// MD5s of local files, valid while their size and modification date stay
  /// the same (hashing a whole library at each backup would take a while).
  struct Index {
    struct Entry: Codable {
      var size: Int64
      var mtime: Double
      var md5: String
    }

    let url: URL
    var entries: [String: Entry]
    var dirty = false

    init(url: URL) {
      self.url = url
      entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    static func stat(_ url: URL) -> (size: Int64, mtime: Double)? {
      guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
            (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
      return ((a[.size] as? NSNumber)?.int64Value ?? 0, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }

    /// nil when the file is missing.
    mutating func md5(_ file: URL) throws -> Data? {
      guard let s = Self.stat(file) else { return nil }
      let name = file.lastPathComponent
      if let e = entries[name], e.size == s.size, e.mtime == s.mtime, let md5 = Data(hex: e.md5) { return md5 }
      let md5 = try Self.hash(file)
      entries[name] = Entry(size: s.size, mtime: s.mtime, md5: SigV4.hex(md5))
      dirty = true
      return md5
    }

    mutating func record(_ file: URL, md5: Data) {
      guard let s = Self.stat(file) else { return }
      entries[file.lastPathComponent] = Entry(size: s.size, mtime: s.mtime, md5: SigV4.hex(md5))
      dirty = true
    }

    func save() {
      guard dirty else { return }
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    static func hash(_ file: URL) throws -> Data {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      var md5 = Insecure.MD5()
      while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { md5.update(data: chunk) }
      return Data(md5.finalize())
    }
  }
}

extension Data {
  init?(hex: String) {
    guard hex.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(hex.count / 2)
    var i = hex.startIndex
    while i < hex.endIndex {
      let j = hex.index(i, offsetBy: 2)
      guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
      bytes.append(b)
      i = j
    }
    self.init(bytes)
  }
}
