import Foundation

/// The catalog calls an import needs (tests use a stub).
public protocol CatalogSource: AnyObject {
  func content(_ id: String) throws -> JSONObject
  func collection(_ id: String) throws -> JSONObject
  /// progress: (bytes received, bytes expected or -1).
  func download(_ url: String, to dest: URL, cancel: CancelToken?, progress: ((Int64, Int64) -> Void)?) throws
}

extension Backend: CatalogSource {}

/// Downloads Merlin catalog episodes into the library. An episode goes into
/// the folder of its collection (made on first use, with the collection's
/// cover); one without a collection goes to "Épisodes Merlin". Episodes
/// already in the library are skipped. Blocking: run it off the main thread.
public final class CatalogImporter: @unchecked Sendable {
  public enum Outcome: Equatable {
    case added(String) // track id
    case alreadyThere
  }

  public struct CollectionSummary: Equatable {
    public var added = 0
    public var skipped = 0
    public var failed: [String] = []
    /// Episodes with protected audio (CatalogFormat.isLocked): PurchaseImporter fetches them.
    public var locked: [SpeakerPurchase] = []
  }

  private let library: MediaLibrary
  private let source: CatalogSource
  private let cancel: CancelToken?
  private let say: (String) -> Void
  private let lock = NSLock()

  /// Bytes this importer expects to download (a collection's missing
  /// episodes, or one episode), when the catalog says.
  public var onExpect: ((Int64) -> Void)?
  /// Audio bytes received so far by this importer, across episodes, and
  /// where the current file will end (0: unknown).
  public var onBytes: ((Int64, Int64) -> Void)?
  private var finishedBytes: Int64 = 0

  /// The catalog's size of an episode's audio (0: unknown).
  public static func size(_ c: JSONObject) -> Int64 {
    Int64(max(c.int("fileSize"), c.int("filesize"), c.int("audio_size")))
  }

  public init(library: MediaLibrary, source: CatalogSource, cancel: CancelToken? = nil, say: @escaping (String) -> Void = { _ in }) {
    self.library = library
    self.source = source
    self.cancel = cancel
    self.say = say
  }

  /// One episode. `json`: what the catalog listing already gave (saves a
  /// request when it has the audio URL); `folder`: where it goes.
  @discardableResult
  /// checkLocked: false when the audio link comes from a sync plan rather than the catalog.
  public func importContent(_ id: String, json: JSONObject? = nil, folder: String? = nil, checkLocked: Bool = true) throws -> Outcome {
    try cancel.check()
    if library.merlinContentIDs().contains(id) { return .alreadyThere }
    var c = json ?? [:]
    if c.str("audio_url") == nil { c = try source.content(id) }
    guard let audioURL = c.str("audio_url"), !audioURL.isEmpty else {
      throw MerlinError("\(c.text("title") ?? "this episode") can't be downloaded (not included in your subscription?)")
    }
    if checkLocked && CatalogFormat.isLocked(c) { throw MerlinError("\(c.text("title") ?? "This episode") is \(CatalogFormat.lockedMessage)") }
    let title = c.text("title") ?? "Épisode"
    let folderID = try folder ?? self.folder(for: c).id

    let audio = library.scratchURL("mp3"), cover = library.scratchURL("jpg")
    defer {
      try? FileManager.default.removeItem(at: audio)
      try? FileManager.default.removeItem(at: cover)
    }
    say("Downloading \(title)…")
    let base = finishedBytes
    try source.download(audioURL, to: audio, cancel: cancel) { [onBytes] received, expected in
      onBytes?(base + received, expected > 0 ? base + expected : 0)
    }
    finishedBytes = base + Int64(MediaLibrary.size(audio))
    onBytes?(finishedBytes, finishedBytes)
    guard MediaLibrary.size(audio) > 0 else { throw MerlinError("\(title): the download is empty") }
    let hasCover = fetchImage(CatalogFormat.imageURL(c), to: cover)

    let ext = URL(string: Backend.lenientURL(audioURL))?.pathExtension.lowercased()
    let episode = c.int("episode")
    let track = try lock.withLock {
      // Another import may have added it meanwhile.
      if library.merlinContentIDs().contains(id) { return nil as MediaLibrary.Track? }
      return try library.insertTrack(folderID: folderID, title: title, artist: c.text("author"),
                                     episode: episode > 0 ? episode : nil, duration: c["duration"] == nil ? nil : c.int("duration"),
                                     audio: audio, ext: ext?.isEmpty == false && ext!.count <= 4 ? ext! : "mp3",
                                     cover: hasCover ? cover : nil, source: .merlin, sourceID: id, sourceName: nil,
                                     position: episode > 0 ? episode - 1 : nil)
    }
    return track.map { .added($0.id) } ?? .alreadyThere
  }

  /// Every episode of a collection, in episode order.
  public func importCollection(_ id: String) throws -> CollectionSummary {
    let col = try source.collection(id)
    var summary = CollectionSummary()
    let all = col.objs("contents").sorted { $0.int("episode") < $1.int("episode") }
    if all.isEmpty { throw MerlinError("\(col.text("title") ?? "this collection") has no episode available") }
    let contents = all.filter { !CatalogFormat.isLocked($0) }
    let have = library.merlinContentIDs()
    summary.locked = all.filter { CatalogFormat.isLocked($0) && !have.contains($0.id("id") ?? "") }.compactMap { c in
      c.id("id").map { SpeakerPurchase(id: $0, title: c.text("title") ?? "Épisode", collectionID: id, size: Self.size(c)) }
    }
    let folder = contents.isEmpty ? nil : try self.folder(collection: col, id: id)
    onExpect?(contents.filter { !have.contains($0.id("id") ?? "") }.reduce(0) { $0 + Self.size($1) })
    for c in contents {
      guard let cid = c.id("id") else { continue }
      do {
        switch try importContent(cid, json: c, folder: folder?.id) {
        case .added: summary.added += 1
        case .alreadyThere: summary.skipped += 1
        }
      } catch let e as CancellationError {
        throw e
      } catch {
        summary.failed.append(c.text("title") ?? cid)
        say("  \(error.userMessage)")
      }
    }
    return summary
  }

  // MARK: Folders

  /// The folder of a collection, made (with its cover) on first use.
  public func folder(collectionID id: String) throws -> MediaLibrary.Folder {
    if let f = library.merlinFolder(collection: id) { return f }
    return try folder(collection: source.collection(id), id: id)
  }

  private func folder(for content: JSONObject) throws -> MediaLibrary.Folder {
    if let col = content.obj("collection"), let id = col.id("id") {
      if let f = library.merlinFolder(collection: id) { return f }
      // The embedded collection often lacks the cover: ask for the full one.
      let full = (try? source.collection(id)) ?? col
      return try folder(collection: full.isEmpty ? col : full, id: id)
    }
    return try lock.withLock {
      if let f = library.folders().first(where: { $0.source == .merlin && $0.sourceID == nil }) { return f }
      return try library.addFolder(MediaLibrary.looseEpisodesFolder, section: MediaLibrary.defaultSections[0], source: .merlin)
    }
  }

  private func folder(collection col: JSONObject, id: String) throws -> MediaLibrary.Folder {
    if let f = library.merlinFolder(collection: id) { return f }
    let cover = library.scratchURL("jpg")
    defer { try? FileManager.default.removeItem(at: cover) }
    let hasCover = fetchImage(CatalogFormat.imageURL(col), to: cover)
    return try lock.withLock {
      if let f = library.merlinFolder(collection: id) { return f }
      return try library.addFolder(col.text("title") ?? "Collection", section: MediaLibrary.defaultSections[0], source: .merlin,
                                   sourceID: id, cover: hasCover ? cover : nil)
    }
  }

  /// Covers are nice to have: a failed download only means no cover.
  private func fetchImage(_ url: URL?, to dest: URL) -> Bool {
    guard let url else { return false }
    do {
      try source.download(url.absoluteString, to: dest, cancel: cancel, progress: nil)
      return CoverImage.isImage(dest)
    } catch {
      return false
    }
  }
}
