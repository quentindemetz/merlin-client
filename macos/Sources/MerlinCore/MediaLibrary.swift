import Foundation

/// The unified media library: one folder holding every audio file and cover,
/// each named after a UUID (`<uuid>.mp3`, `<uuid>.jpg`), plus
/// `Library.sqlite` with everything known about them. The database only
/// stores file names relative to that folder, so the folder can be moved,
/// copied or opened from another Mac as is.
///
/// Media is organised in folders (a Merlin collection, an album, or one you
/// make), each placed in a speaker section (Histoires, Musique…). Sync
/// targets (a speaker, an iPod) get every folder except the ones excluded
/// for them.
///
/// Thread-safe; file work (probing, transcoding, downloading) happens
/// outside the database lock.
public final class MediaLibrary: @unchecked Sendable {
  public static let databaseName = "Library.sqlite"
  static let schemaVersion = 2
  public static let defaultSections = ["Histoires", "Musique", "Documentaires"]
  public static let fallbackFolder = "Mes fichiers"
  public static let looseEpisodesFolder = "Épisodes Merlin"

  public enum Source: String, Sendable {
    case merlin, file
  }

  public struct Folder: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    /// The speaker section it goes into.
    public var section: String
    /// Cover file name in the library folder.
    public var cover: String?
    public var source: Source
    /// Merlin collection id.
    public var sourceID: String?
    public var position: Int
    public var addedAt: Int
  }

  public struct Track: Identifiable, Hashable, Sendable {
    public let id: String
    public var folderID: String
    public var title: String
    public var artist: String?
    /// Episode or track number, from Merlin or the file's tags.
    public var episode: Int?
    public var position: Int
    /// Seconds.
    public var duration: Int?
    /// Audio file name in the library folder.
    public var audio: String
    public var size: Int
    public var cover: String?
    public var source: Source
    /// Merlin content id.
    public var sourceID: String?
    /// The imported file's original name.
    public var sourceName: String?
    public var addedAt: Int
    /// An MP3 the speaker plays as is (44.1 kHz, up to 192 kbps); other
    /// files get a converted copy at sync time.
    public var speakerReady = true

    public var isMP3: Bool { audio.lowercased().hasSuffix(".mp3") }
  }

  public enum ImportDestination: Sendable {
    /// An existing folder.
    case folder(String)
    /// The folder named after the file's album tag (created in `section` if
    /// needed); files without one go to "Mes fichiers".
    case byAlbum(section: String)
  }

  public let root: URL
  let db: SQLite
  private let lock = NSRecursiveLock()

  /// Opens the library in root, creating the folder and database if needed.
  public init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    db = try SQLite(url: root.appendingPathComponent(Self.databaseName))
    try migrate()
    if meta("library_id") == nil { setMeta("library_id", Self.newID()) }
  }

  /// Identifies this library across moves, copies and restores (a backup
  /// only ever replaces the backup of the same library).
  public var libraryID: String { meta("library_id") ?? "" }

  public static func exists(at root: URL) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(databaseName).path)
  }

  private func migrate() throws {
    let version = db.userVersion
    guard version < Self.schemaVersion else {
      if version > Self.schemaVersion { throw MerlinError("this library was made by a newer version of Merlin") }
      return
    }
    try db.transaction {
      if version < 1 { try createV1() }
      if version < 2 {
        // Files were all speaker-ready MP3s before originals were kept.
        try db.exec("ALTER TABLE tracks ADD COLUMN speaker_ready INTEGER NOT NULL DEFAULT 1")
      }
      // New libraries have covers embedded from the start.
      if version == 0 { try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('artwork_embedded', '1')") }
      db.userVersion = Self.schemaVersion
    }
  }

  private func createV1() throws {
    do {
      try db.exec("""
        CREATE TABLE IF NOT EXISTS folders (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          section TEXT NOT NULL,
          cover TEXT,
          source TEXT NOT NULL,
          source_id TEXT,
          position INTEGER NOT NULL,
          added_at INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS folders_merlin ON folders(source_id) WHERE source = 'merlin' AND source_id IS NOT NULL;
        CREATE TABLE IF NOT EXISTS tracks (
          id TEXT PRIMARY KEY,
          folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
          title TEXT NOT NULL,
          artist TEXT,
          episode INTEGER,
          position INTEGER NOT NULL,
          duration INTEGER,
          audio TEXT NOT NULL,
          size INTEGER NOT NULL,
          cover TEXT,
          source TEXT NOT NULL,
          source_id TEXT,
          source_name TEXT,
          added_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS tracks_folder ON tracks(folder_id, position);
        CREATE UNIQUE INDEX IF NOT EXISTS tracks_merlin ON tracks(source_id) WHERE source = 'merlin';
        CREATE TABLE IF NOT EXISTS sync_exclusions (
          target TEXT NOT NULL,
          folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
          PRIMARY KEY (target, folder_id)
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """)
    }
  }

  // MARK: Files

  /// A file of the library (names are always "<uuid>.<ext>").
  public func url(_ name: String) -> URL { root.appendingPathComponent((name as NSString).lastPathComponent) }

  static func newID() -> String { UUID().uuidString.lowercased() }
  static var now: Int { Int(Date().timeIntervalSince1970) }

  public static func size(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
  }

  /// A scratch file inside the library folder (same volume, so moving it in
  /// is atomic); hidden, and cleaned up if left behind.
  func scratchURL(_ ext: String = "part") -> URL { root.appendingPathComponent(".\(Self.newID()).\(ext)") }

  /// Puts a cover in the library as <id>.jpg; returns its name.
  func storeCover(_ image: URL, id: String) throws -> String {
    let name = "\(id).jpg"
    let tmp = scratchURL("jpg")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try CoverImage.normalize(image, to: tmp)
    try replace(url(name), with: tmp)
    return name
  }

  func replace(_ dest: URL, with src: URL) throws {
    if FileManager.default.fileExists(atPath: dest.path) {
      _ = try FileManager.default.replaceItemAt(dest, withItemAt: src)
    } else {
      try FileManager.default.moveItem(at: src, to: dest)
    }
  }

  private func delete(_ name: String?) {
    guard let name else { return }
    try? FileManager.default.removeItem(at: url(name))
  }

  /// Leftover scratch files from interrupted imports.
  public func cleanScratch() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    for n in names where n.hasPrefix(".") && UUID(uuidString: String(n.dropFirst().prefix(36))) != nil {
      try? FileManager.default.removeItem(at: root.appendingPathComponent(n))
    }
  }

  // MARK: Reading

  public func folders() -> [Folder] {
    ((try? db.query("SELECT * FROM folders ORDER BY position, added_at, title")) ?? []).compactMap(Self.folder)
  }

  public func folder(_ id: String) -> Folder? {
    (try? db.query("SELECT * FROM folders WHERE id = ?", [id]))?.first.flatMap(Self.folder)
  }

  public func tracks(in folderID: String) -> [Track] {
    ((try? db.query("SELECT * FROM tracks WHERE folder_id = ? ORDER BY position, episode, title", [folderID])) ?? []).compactMap(Self.track)
  }

  public func allTracks() -> [Track] {
    ((try? db.query("SELECT * FROM tracks ORDER BY folder_id, position, episode, title")) ?? []).compactMap(Self.track)
  }

  public func track(_ id: String) -> Track? {
    (try? db.query("SELECT * FROM tracks WHERE id = ?", [id]))?.first.flatMap(Self.track)
  }

  public var trackCount: Int { (try? db.query("SELECT COUNT(*) AS n FROM tracks"))?.first?["n"]?.int ?? 0 }
  public var totalSize: Int { (try? db.query("SELECT SUM(size) AS n FROM tracks"))?.first?["n"]?.int ?? 0 }

  /// Track counts and sizes per folder.
  public func folderStats() -> [String: (tracks: Int, size: Int, duration: Int)] {
    let rows = (try? db.query("SELECT folder_id, COUNT(*) AS n, SUM(size) AS s, SUM(duration) AS d FROM tracks GROUP BY folder_id")) ?? []
    var out: [String: (Int, Int, Int)] = [:]
    for r in rows {
      guard let id = r["folder_id"]?.string else { continue }
      out[id] = (r["n"]?.int ?? 0, r["s"]?.int ?? 0, r["d"]?.int ?? 0)
    }
    return out
  }

  /// Merlin content ids already in the library.
  public func merlinContentIDs() -> Set<String> {
    let rows = (try? db.query("SELECT source_id FROM tracks WHERE source = 'merlin' AND source_id IS NOT NULL")) ?? []
    return Set(rows.compactMap { $0["source_id"]?.string })
  }

  /// Merlin collection id -> how many of its episodes are in the library.
  public func merlinCollectionCounts() -> [String: Int] {
    let rows = (try? db.query("""
      SELECT f.source_id AS id, COUNT(t.id) AS n FROM folders f JOIN tracks t ON t.folder_id = f.id
      WHERE f.source = 'merlin' AND f.source_id IS NOT NULL AND t.source = 'merlin' GROUP BY f.source_id
      """)) ?? []
    var out: [String: Int] = [:]
    for r in rows { if let id = r["id"]?.string { out[id] = r["n"]?.int ?? 0 } }
    return out
  }

  public func merlinFolder(collection id: String) -> Folder? {
    (try? db.query("SELECT * FROM folders WHERE source = 'merlin' AND source_id = ?", [id]))?.first.flatMap(Self.folder)
  }

  /// Audio files the database lists but the folder lacks.
  public func missingFiles() -> [Track] {
    allTracks().filter { !FileManager.default.fileExists(atPath: url($0.audio).path) }
  }

  /// Every section a folder uses, the defaults, and the speaker's own.
  public func sections() -> [String] {
    var seen = Set<String>()
    let speaker = (meta("speaker_sections") ?? "").split(separator: "\n").map(String.init)
    return (speaker + Self.defaultSections + folders().map(\.section)).filter {
      !$0.isEmpty && seen.insert(SpeakerPlaylist.normalized($0)).inserted
    }
  }

  // MARK: Folders

  @discardableResult
  public func addFolder(_ title: String, section: String, source: Source = .file, sourceID: String? = nil,
                        cover: URL? = nil) throws -> Folder {
    let title = try Self.clean(title)
    let id = Self.newID()
    let coverName = try cover.map { try storeCover($0, id: id) }
    return try lock.withLock {
      let position = ((try db.query("SELECT MAX(position) AS p FROM folders")).first?["p"]?.int ?? -1) + 1
      let folder = Folder(id: id, title: title, section: section.isEmpty ? Self.defaultSections[0] : section, cover: coverName,
                          source: source, sourceID: sourceID, position: position, addedAt: Self.now)
      do {
        try db.run("INSERT INTO folders (id, title, section, cover, source, source_id, position, added_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                   [folder.id, folder.title, folder.section, folder.cover, folder.source.rawValue, folder.sourceID, folder.position, folder.addedAt])
      } catch {
        delete(coverName)
        throw error
      }
      return folder
    }
  }

  public func renameFolder(_ id: String, to title: String) throws {
    try db.run("UPDATE folders SET title = ? WHERE id = ?", [try Self.clean(title), id])
  }

  public func setSection(_ id: String, to section: String) throws {
    let s = section.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { throw MerlinError("the section can't be empty") }
    try db.run("UPDATE folders SET section = ? WHERE id = ?", [s, id])
  }

  /// A new cover from any image file (nil removes it).
  public func setFolderCover(_ id: String, image: URL?) throws {
    guard let folder = folder(id) else { throw MerlinError("unknown folder") }
    if let image {
      let name = try storeCover(image, id: id)
      try db.run("UPDATE folders SET cover = ? WHERE id = ?", [name, id])
    } else {
      try db.run("UPDATE folders SET cover = NULL WHERE id = ?", [id])
      delete(folder.cover)
    }
  }

  /// Removes the folder, its tracks and their files.
  public func removeFolder(_ id: String) throws {
    let doomed = tracks(in: id)
    let folder = folder(id)
    try db.run("DELETE FROM folders WHERE id = ?", [id])
    for t in doomed {
      delete(t.audio)
      delete(t.cover)
    }
    delete(folder?.cover)
  }

  /// A folder without a cover takes the first one of its tracks' (an album
  /// imported from files shows its artwork). Returns true if it got one.
  @discardableResult
  public func adoptCover(_ folderID: String) -> Bool {
    guard let f = folder(folderID), f.cover == nil,
          let art = tracks(in: folderID).compactMap(\.cover).first(where: { FileManager.default.fileExists(atPath: url($0).path) })
    else { return false }
    let name = "\(folderID).jpg", tmp = scratchURL("jpg")
    do {
      try FileManager.default.copyItem(at: url(art), to: tmp)
      try replace(url(name), with: tmp)
      try db.run("UPDATE folders SET cover = ? WHERE id = ? AND cover IS NULL", [name, folderID])
      return true
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      return false
    }
  }

  /// Gives every coverless folder its tracks' cover, if they have one.
  /// Returns the tracks that now show it (to embed it in their files).
  public func adoptCovers() -> [String] {
    folders().filter { $0.cover == nil && adoptCover($0.id) }.flatMap { tracksUsingFolderCover($0.id) }
  }

  /// Moves folders to the given order.
  public func reorderFolders(_ ids: [String]) throws {
    try db.transaction {
      for (i, id) in ids.enumerated() { try db.run("UPDATE folders SET position = ? WHERE id = ?", [i, id]) }
    }
  }

  // MARK: Tracks

  public func renameTrack(_ id: String, to title: String) throws {
    try db.run("UPDATE tracks SET title = ? WHERE id = ?", [try Self.clean(title), id])
  }

  public func moveTracks(_ ids: [String], to folderID: String) throws {
    guard folder(folderID) != nil else { throw MerlinError("unknown folder") }
    try db.transaction {
      var next = nextPosition(folderID)
      for id in ids {
        try db.run("UPDATE tracks SET folder_id = ?, position = ? WHERE id = ?", [folderID, next, id])
        next += 1
      }
    }
    adoptCover(folderID)
  }

  /// Removes tracks and their files; folders left empty stay.
  public func removeTracks(_ ids: [String]) throws {
    let doomed = ids.compactMap(track)
    try db.transaction {
      for t in doomed { try db.run("DELETE FROM tracks WHERE id = ?", [t.id]) }
    }
    for t in doomed {
      delete(t.audio)
      delete(t.cover)
    }
  }

  private func nextPosition(_ folderID: String) -> Int {
    ((try? db.query("SELECT MAX(position) AS p FROM tracks WHERE folder_id = ?", [folderID]))?.first?["p"]?.int ?? -1) + 1
  }

  /// Adds a track whose audio (and optional cover) are scratch files:
  /// they are moved into the library under the track's id.
  func insertTrack(id: String = newID(), folderID: String, title: String, artist: String?, episode: Int?, duration: Int?,
                   audio: URL, ext: String = "mp3", cover: URL?, source: Source, sourceID: String?, sourceName: String?,
                   position: Int? = nil, speakerReady: Bool = true) throws -> Track {
    let audioName = "\(id).\(ext)"
    var coverName: String?
    if let cover { coverName = try? storeCover(cover, id: id) }
    do {
      // The cover goes inside the MP3 too (the folder's when the track has none).
      if ext == "mp3", let art = coverName ?? folder(folderID)?.cover, let jpeg = try? Data(contentsOf: url(art)) {
        try ID3.setCover(jpeg, in: audio, scratch: scratchURL("mp3"))
      }
      try replace(url(audioName), with: audio)
      return try lock.withLock {
        let t = Track(id: id, folderID: folderID, title: try Self.clean(title), artist: artist, episode: episode,
                      position: position ?? nextPosition(folderID), duration: duration, audio: audioName,
                      size: Self.size(url(audioName)), cover: coverName, source: source, sourceID: sourceID,
                      sourceName: sourceName, addedAt: Self.now, speakerReady: speakerReady)
        defer {
          // An album's first artwork becomes its folder's, and goes into
          // the tracks stored before it that had none.
          if coverName != nil, adoptCover(folderID) {
            try? embedArtwork(tracksUsingFolderCover(folderID), strip: false)
          }
        }
        try db.run("""
          INSERT INTO tracks (id, folder_id, title, artist, episode, position, duration, audio, size, cover, source, source_id, source_name, added_at, speaker_ready)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """, [t.id, t.folderID, t.title, t.artist, t.episode, t.position, t.duration, t.audio, t.size, t.cover,
                t.source.rawValue, t.sourceID, t.sourceName, t.addedAt, t.speakerReady])
        return t
      }
    } catch {
      delete(audioName)
      delete(coverName)
      throw error
    }
  }

  // MARK: Artwork in the files

  /// Writes each track's cover (else its folder's) into its MP3; with no
  /// cover at all, `strip` removes the file's pictures. Rewrites the files:
  /// slow, run it off the main thread.
  public func embedArtwork(_ ids: [String], strip: Bool = true, cancel: CancelToken? = nil) throws {
    var covers: [String: Data] = [:]
    for id in ids {
      try cancel.check()
      guard let t = track(id), t.audio.hasSuffix(".mp3"), FileManager.default.fileExists(atPath: url(t.audio).path) else { continue }
      let name = t.cover ?? folder(t.folderID)?.cover
      let jpeg = name.flatMap { n in covers[n] ?? (try? Data(contentsOf: url(n))).map { covers[n] = $0; return $0 } }
      guard jpeg != nil || strip else { continue }
      try ID3.setCover(jpeg, in: url(t.audio), scratch: scratchURL("mp3"))
      try db.run("UPDATE tracks SET size = ? WHERE id = ?", [Self.size(url(t.audio)), t.id])
    }
  }

  /// Tracks shown with their folder's cover.
  public func tracksUsingFolderCover(_ folderID: String) -> [String] {
    tracks(in: folderID).filter { $0.cover == nil }.map(\.id)
  }

  /// Libraries made before covers went into the files: their MP3s, once.
  public func tracksWithoutEmbeddedArtwork() -> [String] {
    guard meta("artwork_embedded") == nil else { return [] }
    return allTracks().filter { $0.audio.hasSuffix(".mp3") }.map(\.id)
  }

  public func markArtworkEmbedded() { setMeta("artwork_embedded", "1") }

  // MARK: Importing files

  /// Imports one audio file from this Mac. MP3, AAC/ALAC, WAV, AIFF and
  /// FLAC are kept as they are; formats macOS can't play (Ogg, Opus, WMA…)
  /// are converted to MP3 at 256 kbps. Devices get converted copies when
  /// they need them. Run it off the main thread.
  @discardableResult
  public func importFile(_ src: URL, into destination: ImportDestination, media: MediaTools = Media()) throws -> (Track, ImportAction) {
    let info = try media.probe(src)
    let srcExt = src.pathExtension.lowercased()
    let keep = Media.keptExtensions.contains(srcExt)
    let ext = keep ? srcExt : "mp3"
    let audio = scratchURL(ext), cover = scratchURL("jpg")
    defer {
      try? FileManager.default.removeItem(at: audio)
      try? FileManager.default.removeItem(at: cover)
    }
    let action: ImportAction
    if keep {
      try FileManager.default.copyItem(at: src, to: audio)
      action = .copied
    } else {
      try media.encodeMP3(src, audio, kbps: Media.qualityKbps)
      action = .transcoded
    }
    let speakerReady = keep && ext == "mp3" && info.isSpeakerReady
    let hasCover = (try? media.extractCover(src, cover, info)) == true

    let folderID: String
    switch destination {
    case .folder(let id):
      guard folder(id) != nil else { throw MerlinError("the folder is gone") }
      folderID = id
    case .byAlbum(let section):
      folderID = try lock.withLock { try fileFolder(named: info.album ?? Self.fallbackFolder, section: section).id }
    }
    let name = info.title ?? src.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
    let track = try insertTrack(folderID: folderID, title: name, artist: info.artist, episode: info.trackNumber,
                                duration: info.duration, audio: audio, ext: ext, cover: hasCover ? cover : nil, source: .file,
                                sourceID: nil, sourceName: src.lastPathComponent, position: info.trackNumber.map { $0 - 1 },
                                speakerReady: speakerReady)
    return (track, action)
  }

  /// Your folder with that title (any section), or a new one.
  func fileFolder(named title: String, section: String) throws -> Folder {
    let key = SpeakerPlaylist.normalized(title)
    if let f = folders().first(where: { $0.source == .file && SpeakerPlaylist.normalized($0.title) == key }) { return f }
    return try addFolder(title, section: section)
  }

  /// Expands folders into the audio files they contain (sorted), keeps files.
  public static func audioFiles(_ urls: [URL]) throws -> [URL] {
    try urls.flatMap { url -> [URL] in
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        throw MerlinError("no such file: \(url.path)")
      }
      guard isDir.boolValue else { return [url] }
      let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
      let found = (walker?.allObjects as? [URL] ?? []).filter { Media.audioExtensions.contains($0.pathExtension.lowercased()) }
      return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
  }

  // MARK: Sync targets

  /// "speaker:<setting id>" or "ipod:<FireWire GUID>".
  public func excludedFolders(_ target: String) -> Set<String> {
    let rows = (try? db.query("SELECT folder_id FROM sync_exclusions WHERE target = ?", [target])) ?? []
    return Set(rows.compactMap { $0["folder_id"]?.string })
  }

  public func setIncluded(_ included: Bool, folders ids: [String], target: String) throws {
    try db.transaction {
      for id in ids {
        if included {
          try db.run("DELETE FROM sync_exclusions WHERE target = ? AND folder_id = ?", [target, id])
        } else {
          try db.run("INSERT OR IGNORE INTO sync_exclusions (target, folder_id) VALUES (?, ?)", [target, id])
        }
      }
    }
  }

  /// The folders (with tracks) a target gets, in library order.
  public func syncedFolders(_ target: String) -> [(Folder, [Track])] {
    let excluded = excludedFolders(target)
    return folders().filter { !excluded.contains($0.id) }.compactMap { f in
      let t = tracks(in: f.id)
      return t.isEmpty ? nil : (f, t)
    }
  }

  // MARK: Backup

  /// A consistent copy of the database, taken while the library stays usable.
  public func snapshot(to dest: URL) throws {
    try? FileManager.default.removeItem(at: dest)
    try db.run("VACUUM INTO ?", [dest.path])
  }

  /// What a library database (e.g. a snapshot) holds: the files it refers
  /// to in the library folder, and its id.
  public struct Contents: Sendable {
    public var libraryID: String?
    public var files: [String]
    public var folders: Int
    public var tracks: Int
  }

  public static func contents(ofDatabase url: URL) throws -> Contents {
    let db = try SQLite(url: url)
    let rows = try db.query("""
      SELECT audio AS name FROM tracks UNION SELECT cover FROM tracks WHERE cover IS NOT NULL
      UNION SELECT cover FROM folders WHERE cover IS NOT NULL
      """)
    func count(_ table: String) -> Int { (try? db.query("SELECT COUNT(*) AS n FROM \(table)"))?.first?["n"]?.int ?? 0 }
    return Contents(libraryID: (try? db.query("SELECT value FROM meta WHERE key = 'library_id'"))?.first?["value"]?.string,
                    files: rows.compactMap { $0["name"]?.string }.map { ($0 as NSString).lastPathComponent }.sorted(),
                    folders: count("folders"), tracks: count("tracks"))
  }

  // MARK: Meta

  public func meta(_ key: String) -> String? {
    (try? db.query("SELECT value FROM meta WHERE key = ?", [key]))?.first?["value"]?.string
  }

  public func setMeta(_ key: String, _ value: String?) {
    if let value {
      _ = try? db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    } else {
      _ = try? db.run("DELETE FROM meta WHERE key = ?", [key])
    }
  }

  // MARK: Rows

  static func clean(_ title: String) throws -> String {
    let t = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !t.isEmpty else { throw MerlinError("the title can't be empty") }
    return t
  }

  private static func folder(_ r: SQLite.Row) -> Folder? {
    guard let id = r["id"]?.string, let title = r["title"]?.string else { return nil }
    return Folder(id: id, title: title, section: r["section"]?.string ?? defaultSections[0], cover: r["cover"]?.string,
                  source: Source(rawValue: r["source"]?.string ?? "") ?? .file, sourceID: r["source_id"]?.string,
                  position: r["position"]?.int ?? 0, addedAt: r["added_at"]?.int ?? 0)
  }

  private static func track(_ r: SQLite.Row) -> Track? {
    guard let id = r["id"]?.string, let folder = r["folder_id"]?.string, let audio = r["audio"]?.string else { return nil }
    return Track(id: id, folderID: folder, title: r["title"]?.string ?? "", artist: r["artist"]?.string,
                 episode: r["episode"]?.int, position: r["position"]?.int ?? 0, duration: r["duration"]?.int,
                 audio: audio, size: r["size"]?.int ?? 0, cover: r["cover"]?.string,
                 source: Source(rawValue: r["source"]?.string ?? "") ?? .file, sourceID: r["source_id"]?.string,
                 sourceName: r["source_name"]?.string, addedAt: r["added_at"]?.int ?? 0,
                 speakerReady: (r["speaker_ready"]?.int ?? 1) != 0)
  }
}
