import CoreGraphics
import CryptoKit
import Foundation

/// Merlin's covers on the iPod: new .ithmb files and ArtworkDB entries for
/// Merlin's tracks, the owner's artwork left alone. Prepared before the
/// iTunesDB is written; `commit` swaps the ArtworkDB in.
struct IPodArtworkUpdate {
  let data: Data
  /// .ithmb files written for this update (deleted again if it's abandoned).
  let newFiles: [URL]
  /// Merlin's files from last time, to delete once everything is written.
  let oldFiles: [String]
  let fileNames: [String]
  let images: Int
}

extension IPodTransfer {
  static let ithmbMaxSize = 256_000_000 // ITHUMB_MAX_SIZE

  var artworkDBURL: URL { device.artworkDir.appendingPathComponent("ArtworkDB") }

  /// Every format libgpod knows, to read an ArtworkDB's format list when
  /// the model is unknown.
  static let knownFormats: [Int: ArtworkFormat] = {
    var out: [Int: ArtworkFormat] = [:]
    for f in ArtworkFormat.photo + ArtworkFormat.nano + ArtworkFormat.video + ArtworkFormat.classic + ArtworkFormat.nano4 { out[f.id] = f }
    return out
  }()

  /// Builds the new ArtworkDB and writes the thumbnails. `covers`: Merlin
  /// tracks (dbid, cover file) in the order given; `merlin`: every dbid
  /// Merlin owns or owned. Links in `db` are updated. nil: this iPod shows
  /// no artwork, or there is none to add or remove.
  func prepareArtwork(_ db: ITunesDB, covers: [(dbid: UInt64, album: String, url: URL)], merlin: Set<UInt64>,
                      oldFiles: [String]) throws -> IPodArtworkUpdate? {
    var artwork: ArtworkDB?
    if let data = try? Data(contentsOf: artworkDBURL) {
      do {
        artwork = try ArtworkDB(data: data)
      } catch {
        say("warning: this iPod's ArtworkDB can't be read (\(error)); covers left out")
        return nil
      }
    }
    var formats = device.coverFormats
    if formats.isEmpty, let known = artwork?.fileList?.children.compactMap({ Self.knownFormats[Int($0.u32(16))] }) {
      formats = known
    }
    guard !formats.isEmpty, artwork != nil || !covers.isEmpty else { return nil }
    let adb = artwork ?? ArtworkDB(formats: formats)
    adb.ensureFormats(formats)
    try fm.createDirectory(at: device.artworkDir, withIntermediateDirectories: true)

    // Merlin's previous images go; the owner's stay.
    adb.imageList?.children.removeAll { merlin.contains(ArtworkDB.songID($0)) }
    let ownerFiles = Set(adb.images.flatMap(ArtworkDB.files))

    // New .ithmb files, one series per format.
    var writers: [Int: ThumbFileWriter] = [:]
    var all: [ThumbFileWriter] = []
    var written: [URL] = []
    func writer(_ f: ArtworkFormat) throws -> ThumbFileWriter {
      if let w = writers[f.id] {
        if w.offset < Self.ithmbMaxSize { return w }
        try w.close()
      }
      let name = freeFileName(f.id, avoiding: ownerFiles.union(written.map(\.lastPathComponent)))
      let url = device.artworkDir.appendingPathComponent(name)
      let w = try ThumbFileWriter(url: url)
      written.append(url)
      writers[f.id] = w
      all.append(w)
      return w
    }

    var count = 0
    do {
      var shared: [String: UInt32] = [:] // sparse iPods: one image per album cover
      var provisional: UInt32 = 0x4000_0000
      var links: [(UInt64, UInt32, Int)] = []
      var imageCache: [URL: (CGImageWrapper, Int, String)] = [:]
      for c in covers {
        try cancel.check()
        let loaded: (CGImageWrapper, Int, String)
        if let hit = imageCache[c.url] {
          loaded = hit
        } else {
          guard let data = try? Data(contentsOf: c.url), let image = CoverRenderer.image(c.url) else { continue }
          let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
          loaded = (CGImageWrapper(image: image), data.count, digest)
          imageCache[c.url] = loaded
        }
        let key = c.album + "\u{0}" + loaded.2
        if device.sparseArtwork, let id = shared[key] {
          links.append((c.dbid, id, loaded.1))
          continue
        }
        var thumbs: [(Thumbnail, file: String, offset: Int)] = []
        for f in formats {
          guard let t = CoverRenderer.thumbnail(loaded.0.image, f) else { continue }
          let w = try writer(f)
          let offset = try w.append(t.pixels)
          thumbs.append((t, w.url.lastPathComponent, offset))
        }
        guard !thumbs.isEmpty else { continue }
        provisional += 1
        adb.imageList?.children.append(ArtworkDB.mhii(imageID: provisional, songID: c.dbid, originalSize: loaded.1, thumbs: thumbs))
        shared[key] = provisional
        links.append((c.dbid, provisional, loaded.1))
        count += 1
      }
      for w in writers.values where !w.closed { try w.close() }

      for (dbid, id, size) in links { db.setArtwork(dbid: dbid, imageID: id, originalSize: size) }
      let map = adb.renumber(trackOrder: db.artworkLinks)
      db.remapArtworkLinks(map)
    } catch {
      for w in all where !w.closed { try? w.close() }
      for url in written { try? fm.removeItem(at: url) }
      throw error
    }

    let data = adb.data()
    _ = try ArtworkDB(data: data) // reads back
    return IPodArtworkUpdate(data: data, newFiles: written,
                             oldFiles: oldFiles.filter { !ownerFiles.contains($0) && !written.map(\.lastPathComponent).contains($0) },
                             fileNames: written.map(\.lastPathComponent), images: count)
  }

  /// Writes the ArtworkDB, keeping the previous one to put back if the
  /// iTunesDB can't be written.
  func commitArtwork(_ update: IPodArtworkUpdate) throws -> URL? {
    var backup: URL?
    if fm.fileExists(atPath: artworkDBURL.path) {
      let previous = device.artworkDir.appendingPathComponent("ArtworkDB.merlin-previous")
      try? fm.removeItem(at: previous)
      try fm.copyItem(at: artworkDBURL, to: previous)
      backup = previous
    }
    let tmp = device.artworkDir.appendingPathComponent("ArtworkDB.merlin-new")
    try update.data.write(to: tmp)
    if fm.fileExists(atPath: artworkDBURL.path) {
      _ = try fm.replaceItemAt(artworkDBURL, withItemAt: tmp)
    } else {
      try fm.moveItem(at: tmp, to: artworkDBURL)
    }
    return backup
  }

  func rollbackArtwork(_ update: IPodArtworkUpdate, backup: URL?) {
    if let backup {
      try? fm.removeItem(at: artworkDBURL)
      try? fm.copyItem(at: backup, to: artworkDBURL)
    } else {
      try? fm.removeItem(at: artworkDBURL)
    }
    for url in update.newFiles { try? fm.removeItem(at: url) }
  }

  func finishArtwork(_ update: IPodArtworkUpdate) {
    for name in update.oldFiles { try? fm.removeItem(at: device.artworkDir.appendingPathComponent(name)) }
  }

  /// F<format>_<n>.ithmb with the lowest n not in use.
  private func freeFileName(_ format: Int, avoiding used: Set<String>) -> String {
    var n = 1
    while true {
      let name = "F\(format)_\(n).ithmb"
      if !used.contains(name), !fm.fileExists(atPath: device.artworkDir.appendingPathComponent(name).path) { return name }
      n += 1
    }
  }
}

/// CGImage isn't Sendable-friendly in tuples; a tiny box.
struct CGImageWrapper { let image: CGImage }

final class ThumbFileWriter {
  let url: URL
  private let handle: FileHandle
  private(set) var offset = 0
  private(set) var closed = false

  init(url: URL) throws {
    self.url = url
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
  }

  func append(_ bytes: [UInt8]) throws -> Int {
    let at = offset
    try handle.write(contentsOf: Data(bytes))
    offset += bytes.count
    return at
  }

  func close() throws {
    closed = true
    try handle.synchronize()
    try handle.close()
  }
}
