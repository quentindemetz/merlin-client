import AudioToolbox
import Foundation

/// What goes on the iPod: the library's folders (except the ones left out
/// for this iPod). A folder becomes an album and a playlist; tracks get
/// their artist, or the folder's section.
public struct IPodContent {
  public struct Item: Equatable {
    public let uuid: String
    public let title: String
    public let album: String
    public let artist: String
    public let trackNumber: Int
    public let trackCount: Int
    public let source: URL
    /// The track's cover, else its folder's.
    public var cover: URL? = nil
  }

  public struct Folder: Equatable {
    public let uuid: String
    public let name: String
    public let items: [String] // uuids
  }

  public var items: [Item] = []
  public var folders: [Folder] = []
  /// Tracks whose audio file is missing from the library folder.
  public var missing: [String] = []

  public static let genre = "Merlin"

  public init() {}

  public static func target(_ device: IPodDevice) -> String { "ipod:\(device.syncID)" }

  /// converted: where MP3 copies of non-MP3 files are cached (nil: such
  /// files are left out).
  public static func build(library: MediaLibrary, target: String, converted: URL? = nil, cancel: CancelToken? = nil,
                           say: @escaping (String) -> Void = { _ in }) throws -> IPodContent {
    var content = IPodContent()
    let synced = library.syncedFolders(target)
    var sendable = DeviceAudio.Result()
    if let converted {
      let audio = DeviceAudio(library: library, cacheDir: converted)
      sendable = try audio.files(for: synced.flatMap(\.1), device: .ipod, cancel: cancel, say: say)
      audio.prune(keeping: Set(library.allTracks().map(\.id)))
    } else {
      for t in synced.flatMap(\.1) where t.isMP3 { sendable.files[t.id] = library.url(t.audio) }
    }
    var names: [String: Int] = [:]
    for (folder, _) in synced { names[SpeakerPlaylist.normalized(folder.title), default: 0] += 1 }

    for (folder, tracks) in synced {
      let folderCover = folder.cover.map(library.url).flatMap(nonEmpty)
      var uuids: [String] = []
      for (i, t) in tracks.enumerated() {
        guard let src = sendable.files[t.id].flatMap(nonEmpty) else {
          content.missing.append(t.title)
          continue
        }
        var item = Item(uuid: t.id, title: t.title, album: folder.title, artist: t.artist ?? folder.section,
                        trackNumber: i + 1, trackCount: tracks.count, source: src)
        item.cover = t.cover.map(library.url).flatMap(nonEmpty) ?? folderCover
        content.items.append(item)
        uuids.append(t.id)
      }
      guard !uuids.isEmpty else { continue }
      // Two folders with the same name: say which section each is in.
      let name = names[SpeakerPlaylist.normalized(folder.title), default: 0] > 1 ? "\(folder.title) (\(folder.section))" : folder.title
      content.folders.append(Folder(uuid: folder.id, name: name, items: uuids))
    }
    return content
  }

  private static func nonEmpty(_ url: URL) -> URL? {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    return size > 0 ? url : nil
  }
}

/// Duration, bitrate and sample rate of an audio file, with Core Audio
/// (what libgpod's callers read from the tags).
public struct AudioFacts: Equatable {
  public let durationMS: Int
  public let bitrate: Int // kbit/s
  public let sampleRate: Int

  public static func read(_ url: URL) throws -> AudioFacts {
    var file: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else {
      throw MerlinError("\(url.lastPathComponent) is not a readable audio file")
    }
    defer { AudioFileClose(file) }
    var duration: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)
    var bitrate: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitrate)
    var format = AudioStreamBasicDescription()
    size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format)
    return AudioFacts(durationMS: Int((duration * 1000).rounded()), bitrate: Int(bitrate / 1000), sampleRate: Int(format.mSampleRate))
  }
}

/// Copies Merlin content to an iPod and updates its database: Merlin's
/// tracks and playlists are replaced, everything else is kept. What Merlin
/// put on the iPod is remembered in iPod_Control/iTunes/Merlin.json.
public final class IPodTransfer: @unchecked Sendable {
  public struct Summary: Equatable {
    public var copied = 0
    public var kept = 0
    public var removed = 0
    public var playlists = 0
    public var covers = 0
  }

  let device: IPodDevice
  private let out: SyncOutput
  let cancel: CancelToken?
  let fm = FileManager.default

  public init(device: IPodDevice, out: SyncOutput, cancel: CancelToken? = nil) {
    self.device = device
    self.out = out
    self.cancel = cancel
  }

  var manifestURL: URL { device.itunesDir.appendingPathComponent("Merlin.json") }

  // MARK: Manifest

  struct Manifest {
    struct Track { var dbid: UInt64; var path: String; var sourceSize: Int }
    var tracks: [String: Track] = [:]
    var playlists: [String: UInt64] = [:] // folder uuid -> playlist id
    var artworkFiles: [String] = []       // Merlin's .ithmb files

    init() {}

    init(_ json: JSONObject) {
      for (uuid, value) in json.obj("tracks") ?? [:] {
        guard let t = value as? JSONObject, let dbid = t.str("dbid").flatMap({ UInt64($0, radix: 16) }), let path = t.str("path") else { continue }
        tracks[uuid] = Track(dbid: dbid, path: path, sourceSize: t.int("source_size"))
      }
      for (uuid, value) in json.obj("playlists") ?? [:] {
        if let id = (value as? String).flatMap({ UInt64($0, radix: 16) }) { playlists[uuid] = id }
      }
      artworkFiles = (json["artwork_files"] as? [String]) ?? []
    }

    var json: JSONObject {
      ["version": 1,
       "tracks": tracks.mapValues { ["dbid": String($0.dbid, radix: 16), "path": $0.path, "source_size": $0.sourceSize] as JSONObject },
       "playlists": playlists.mapValues { String($0, radix: 16) },
       "artwork_files": artworkFiles]
    }
  }

  func loadManifest() -> Manifest {
    guard let data = try? Data(contentsOf: manifestURL), let json = try? JSON.parse(data) as? JSONObject else { return Manifest() }
    return Manifest(json)
  }

  // MARK: Database

  /// Reads the database, or makes an empty one for an iPod never used with
  /// iTunes (libgpod's itdb_init_ipod).
  public func loadDatabase() throws -> ITunesDB {
    if let data = try? Data(contentsOf: device.databaseURL) {
      do {
        return try ITunesDB(data: data)
      } catch {
        throw MerlinError("can't read this iPod's music database: \(error)")
      }
    }
    say("No music database on this iPod yet; creating one.")
    try fm.createDirectory(at: device.itunesDir, withIntermediateDirectories: true)
    return ITunesDB(name: device.volumeName)
  }

  /// The F00...Fnn folders music goes into.
  func musicFolders() throws -> [String] {
    try fm.createDirectory(at: device.musicDir, withIntermediateDirectories: true)
    var dirs = ((try? fm.contentsOfDirectory(atPath: device.musicDir.path)) ?? [])
      .filter { $0.count == 3 && $0.uppercased().hasPrefix("F") && Int($0.dropFirst()) != nil }.sorted()
    if dirs.isEmpty {
      dirs = (0..<20).map { String(format: "F%02d", $0) }
      for d in dirs { try fm.createDirectory(at: device.musicDir.appendingPathComponent(d), withIntermediateDirectories: true) }
    }
    return dirs
  }

  func fileURL(_ ipodPath: String) -> URL {
    device.mountPoint.appendingPathComponent(ipodPath.split(separator: ":").joined(separator: "/"))
  }

  // MARK: Transfer

  @discardableResult
  public func run(_ content: IPodContent) throws -> Summary {
    let db = try loadDatabase()
    if let problem = device.problem(existing: db) { throw MerlinError(problem) }
    var manifest = loadManifest()
    var summary = Summary()

    // The iPod's own records refer to tracks by position: fold them in now,
    // before positions change (libgpod does the same when reading).
    let onTheGo = try readDeviceRecords(db)

    let folders = try musicFolders()
    let inDB = Set(db.dbids)
    var tracks: [ITunesTrack] = []
    var toCopy: [(IPodContent.Item, String)] = []
    var obsolete: [String] = [] // ipod paths to delete once the database is written
    var newManifest = Manifest()
    var covers: [(dbid: UInt64, album: String, url: URL)] = []

    for item in content.items {
      try cancel.check()
      let size = Self.size(item.source)
      let previous = manifest.tracks[item.uuid]
      var path: String
      if let p = previous, inDB.contains(p.dbid), p.sourceSize == size, Self.size(fileURL(p.path)) == size {
        path = p.path
        summary.kept += 1
      } else {
        path = try newPath(folders)
        if let p = previous { obsolete.append(p.path) }
        toCopy.append((item, path))
      }
      let facts: AudioFacts
      do {
        facts = try AudioFacts.read(item.source)
      } catch {
        say("  skipped \(item.title): \(error.userMessage)")
        toCopy.removeAll { $0.0.uuid == item.uuid }
        continue
      }
      let dbid = previous?.dbid ?? ITunesDB.randomID()
      tracks.append(ITunesTrack(title: item.title, album: item.album, artist: item.artist, genre: IPodContent.genre,
                                trackNumber: item.trackNumber, trackCount: item.trackCount, size: size,
                                durationMS: facts.durationMS, bitrate: facts.bitrate, sampleRate: facts.sampleRate,
                                ipodPath: path, dbid: dbid))
      newManifest.tracks[item.uuid] = Manifest.Track(dbid: dbid, path: path, sourceSize: size)
      if let cover = item.cover { covers.append((dbid, item.album, cover)) }
    }
    for (uuid, t) in manifest.tracks where newManifest.tracks[uuid] == nil {
      obsolete.append(t.path)
      summary.removed += 1
    }

    let needed = toCopy.reduce(Int64(0)) { $0 + Int64(Self.size($1.0.source)) }
    let freed = obsolete.reduce(Int64(0)) { $0 + Int64(Self.size(fileURL($1))) }
    let margin: Int64 = 20 << 20
    if needed - freed + margin > device.freeSpace {
      throw MerlinError("not enough space on the iPod: \(Self.megabytes(needed)) needed, \(Self.megabytes(device.freeSpace)) free")
    }

    // Copy, and undo the copies if anything fails before the database is written.
    var copied: [URL] = []
    do {
      for (i, (item, path)) in toCopy.enumerated() {
        try cancel.check()
        let dest = fileURL(path)
        copied.append(dest)
        try copy(item.source, to: dest, label: "  [\(i + 1)/\(toCopy.count)] \(item.title)")
        summary.copied += 1
      }

      var playlists: [ITunesPlaylist] = []
      let wanted = Set(tracks.map(\.dbid))
      for f in content.folders {
        let ids = f.items.compactMap { newManifest.tracks[$0]?.dbid }.filter(wanted.contains)
        guard !ids.isEmpty else { continue }
        let id = manifest.playlists[f.uuid] ?? ITunesDB.randomID()
        newManifest.playlists[f.uuid] = id
        playlists.append(ITunesPlaylist(name: f.name, id: id, trackDBIDs: ids))
      }
      summary.playlists = playlists.count
      for (i, ids) in onTheGo.enumerated() {
        playlists.append(ITunesPlaylist(name: "On-The-Go \(i + 1)", id: ITunesDB.randomID(), trackDBIDs: ids))
      }

      let merlinDBIDs = Set(manifest.tracks.values.map(\.dbid))
      db.replace(tracks: tracks, removing: merlinDBIDs, playlists: playlists,
                 removingPlaylists: Set(manifest.playlists.values))

      // Covers: thumbnails and ArtworkDB first, then the iTunesDB.
      newManifest.artworkFiles = manifest.artworkFiles
      var art: IPodArtworkUpdate?
      do {
        if !covers.isEmpty { say("Preparing covers…") }
        art = try prepareArtwork(db, covers: covers, merlin: merlinDBIDs.union(tracks.map(\.dbid)), oldFiles: manifest.artworkFiles)
      } catch let e as CancellationError {
        throw e
      } catch {
        say("warning: covers left out (\(error.userMessage))")
      }
      let backup = try art.map(commitArtwork)
      do {
        try write(db)
      } catch {
        if let art { rollbackArtwork(art, backup: backup ?? nil) }
        throw error
      }
      if let art {
        finishArtwork(art)
        newManifest.artworkFiles = art.fileNames
        summary.covers = art.images
      }
    } catch {
      for url in copied { try? fm.removeItem(at: url) }
      throw error
    }

    manifest = newManifest
    try JSON.data(manifest.json, pretty: true).write(to: manifestURL, options: .atomic)
    clearDeviceRecords()
    for path in Set(obsolete) where !manifest.tracks.values.contains(where: { $0.path == path }) {
      try? fm.removeItem(at: fileURL(path))
    }
    Darwin.sync()
    return summary
  }

  /// Takes everything Merlin put on the iPod off it.
  @discardableResult
  public func removeAll() throws -> Int {
    let db = try loadDatabase()
    if let problem = device.problem(existing: db) { throw MerlinError(problem) }
    let manifest = loadManifest()
    let onTheGo = try readDeviceRecords(db)
    let removed = Set(manifest.tracks.values.map(\.dbid))
    let otg = onTheGo.enumerated().map { ITunesPlaylist(name: "On-The-Go \($0 + 1)", id: ITunesDB.randomID(), trackDBIDs: $1) }
    db.replace(tracks: [], removing: removed, playlists: otg, removingPlaylists: Set(manifest.playlists.values))
    let art = try? prepareArtwork(db, covers: [], merlin: removed, oldFiles: manifest.artworkFiles)
    let backup = try art.map(commitArtwork)
    do {
      try write(db)
    } catch {
      if let art { rollbackArtwork(art, backup: backup ?? nil) }
      throw error
    }
    if let art { finishArtwork(art) }
    try? fm.removeItem(at: manifestURL)
    clearDeviceRecords()
    for t in manifest.tracks.values { try? fm.removeItem(at: fileURL(t.path)) }
    Darwin.sync()
    return manifest.tracks.count
  }

  /// What Merlin put on the iPod last time, if anything.
  public func merlinTrackCount() -> Int { loadManifest().tracks.count }

  /// Applies "Play Counts" and returns the On-The-Go playlists (as dbids).
  private func readDeviceRecords(_ db: ITunesDB) throws -> [[UInt64]] {
    let playCounts = device.itunesDir.appendingPathComponent("Play Counts")
    if let data = try? Data(contentsOf: playCounts), !data.isEmpty {
      do { try db.applyPlayCounts(data) } catch { say("  note: ignored the iPod's play counts (\(error))") }
    }
    var lists: [[UInt64]] = []
    for url in onTheGoFiles() {
      guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
      if let ids = try? db.onTheGoTracks(data), !ids.isEmpty { lists.append(ids) }
    }
    return lists
  }

  private func onTheGoFiles() -> [URL] {
    var urls = [device.itunesDir.appendingPathComponent("OTGPlaylistInfo")]
    for i in 1...20 { urls.append(device.itunesDir.appendingPathComponent("OTGPlaylistInfo_\(i)")) }
    return urls.filter { fm.fileExists(atPath: $0.path) }
  }

  /// libgpod's itdb_rename_files: play counts are now in the database.
  private func clearDeviceRecords() {
    let playCounts = device.itunesDir.appendingPathComponent("Play Counts")
    if fm.fileExists(atPath: playCounts.path) {
      let bak = device.itunesDir.appendingPathComponent("Play Counts.bak")
      try? fm.removeItem(at: bak)
      try? fm.moveItem(at: playCounts, to: bak)
    }
    for url in onTheGoFiles() { try? fm.removeItem(at: url) }
  }

  /// Serializes, signs if needed, checks the result reads back, keeps a
  /// backup and replaces the database atomically.
  private func write(_ db: ITunesDB) throws {
    var data = db.data()
    if device.checksum(existing: db) == .hash58 {
      guard let fw = device.firewireID else { throw MerlinError("can't sign the database: unknown FireWire ID") }
      try ITunesDB.writeHash58(&data, firewireID: fw)
    }
    let check = try ITunesDB(data: data)
    guard check.trackCount == db.trackCount else { throw MerlinError("the new database doesn't read back correctly; nothing was changed") }

    let url = device.databaseURL
    if fm.fileExists(atPath: url.path) {
      let original = device.itunesDir.appendingPathComponent("iTunesDB.before-merlin")
      if !fm.fileExists(atPath: original.path) { try fm.copyItem(at: url, to: original) }
      let previous = device.itunesDir.appendingPathComponent("iTunesDB.merlin-previous")
      try? fm.removeItem(at: previous)
      try fm.copyItem(at: url, to: previous)
    }
    let tmp = device.itunesDir.appendingPathComponent("iTunesDB.merlin-new")
    try data.write(to: tmp)
    let fd = open(tmp.path, O_RDONLY)
    if fd >= 0 { fsync(fd); close(fd) }
    if fm.fileExists(atPath: url.path) {
      _ = try fm.replaceItemAt(url, withItemAt: tmp)
    } else {
      try fm.moveItem(at: tmp, to: url)
    }
    say("Music database updated (\(db.trackCount) tracks on the iPod).")
  }

  /// A new file name, iTunes-style: Music/Fxx/ABCD.mp3.
  private func newPath(_ folders: [String]) throws -> String {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    for _ in 0..<1000 {
      let dir = folders.randomElement()!
      let name = "MRL" + String((0..<5).map { _ in letters.randomElement()! }) + ".mp3"
      let path = ":iPod_Control:Music:\(dir):\(name)"
      if !fm.fileExists(atPath: fileURL(path).path) { return path }
    }
    throw MerlinError("could not find a free file name on the iPod")
  }

  private func copy(_ src: URL, to dest: URL, label: String) throws {
    let input = try FileHandle(forReadingFrom: src)
    defer { try? input.close() }
    fm.createFile(atPath: dest.path, contents: nil)
    let output = try FileHandle(forWritingTo: dest)
    defer { try? output.close() }
    let total = max(Self.size(src), 1)
    var done = 0
    while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
      try cancel.check()
      try output.write(contentsOf: chunk)
      done += chunk.count
      out.print("\r\(label) \(done * 100 / total)%")
    }
    try output.synchronize()
    out.print("\r\(label) copied\n")
  }

  func say(_ s: String) { out.print(s + "\n") }

  static func size(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
  }

  static func megabytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
