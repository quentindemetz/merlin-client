import Foundation
import ImageIO
@testable import MerlinCore
import Testing

/// Probes like FakeMedia, with tags.
struct TaggedMedia: MediaTools {
  var album: String?
  var track: Int?
  var cover = false
  var bitRate = 128_000
  /// Conversions made (dest file names), across copies of this value.
  var log = Locked<[String]>([])

  func probe(_ path: URL) throws -> MediaInfo {
    MediaInfo(title: path.deletingPathExtension().lastPathComponent.capitalized, artist: "Henri Dès", album: album, trackNumber: track,
              duration: 61, codec: path.pathExtension == "mp3" ? "mp3" : "vorbis", sampleRate: 44_100, channels: 2, bitRate: bitRate,
              hasCover: cover)
  }
  func prepareAudio(_ src: URL, _ dest: URL, _ info: MediaInfo) throws -> ImportAction {
    if info.isSpeakerReady {
      try FileManager.default.copyItem(at: src, to: dest)
      return .copied
    }
    log.mutate { $0.append("speaker \(src.lastPathComponent)") }
    try silentMP3(frames: 7).write(to: dest)
    return .transcoded
  }
  func encodeMP3(_ src: URL, _ dest: URL, kbps: Int) throws {
    log.mutate { $0.append("\(kbps)k \(src.lastPathComponent)") }
    try silentMP3(frames: 9).write(to: dest)
  }
  func extractCover(_ src: URL, _ dest: URL, _ info: MediaInfo) throws -> Bool {
    guard cover else { return false }
    try solidImage(dest, width: 1000, height: 800, rgb: (0, 0, 1))
    return true
  }
  func folderCover(_ title: String, _ dest: URL) throws { try Data("cover titled \(title)".utf8).write(to: dest) }
}

@Suite final class MediaLibraryTests {
  let dir = tempDir()
  lazy var root = dir.appendingPathComponent("Merlin Library")
  deinit { try? FileManager.default.removeItem(at: dir) }

  func source(_ name: String) throws -> URL {
    let u = dir.appendingPathComponent(name)
    try silentMP3(frames: 20).write(to: u)
    return u
  }

  @Test func importsGoIntoAFolderPerAlbum() throws {
    let lib = try MediaLibrary(root: root)
    let (a, action) = try lib.importFile(try source("le loup.mp3"), into: .byAlbum(section: "Musique"),
                                         media: TaggedMedia(album: "Comptines", track: 2, cover: true))
    #expect(action == .copied)
    try lib.importFile(try source("la souris.mp3"), into: .byAlbum(section: "Musique"), media: TaggedMedia(album: "comptines", track: 1))
    try lib.importFile(try source("sans_album.mp3"), into: .byAlbum(section: "Musique"), media: TaggedMedia())

    #expect(lib.folders().map(\.title) == ["Comptines", "Mes fichiers"])
    let comptines = lib.folders()[0]
    #expect(comptines.section == "Musique")
    #expect(lib.tracks(in: comptines.id).map(\.title) == ["La Souris", "Le Loup"]) // by track number
    #expect(a.artist == "Henri Dès" && a.duration == 61 && a.sourceName == "le loup.mp3")
    // Files are named after the track's UUID, next to the database.
    #expect(a.audio == "\(a.id).mp3" && a.cover == "\(a.id).jpg")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(a.audio).path))
    #expect(a.size == MediaLibrary.size(root.appendingPathComponent(a.audio)))
    // The cover is scaled down to 600 px.
    let src = try #require(CGImageSourceCreateWithURL(lib.url(a.cover!) as CFURL, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 600 && props[kCGImagePropertyPixelHeight] as? Int == 480)
    #expect(lib.trackCount == 3)
  }

  @Test func theFolderIsPortable() throws {
    let lib = try MediaLibrary(root: root)
    let folder = try lib.addFolder("Contes", section: "Histoires")
    let (t, _) = try lib.importFile(try source("a.mp3"), into: .folder(folder.id), media: TaggedMedia(cover: true))
    try lib.setIncluded(false, folders: [folder.id], target: "ipod:X")

    // No absolute path anywhere in the database.
    let db = try Data(contentsOf: root.appendingPathComponent(MediaLibrary.databaseName))
    #expect(db.range(of: Data(dir.path.utf8)) == nil)
    #expect(db.range(of: Data("/Users".utf8)) == nil)

    // Moved elsewhere, it opens with everything in place.
    let moved = dir.appendingPathComponent("elsewhere/Copy")
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: root, to: moved)
    let again = try MediaLibrary(root: moved)
    let back = try #require(again.track(t.id))
    #expect(back.title == "A" && back.folderID == folder.id)
    #expect(FileManager.default.fileExists(atPath: again.url(back.audio).path))
    #expect(again.missingFiles().isEmpty)
    #expect(again.excludedFolders("ipod:X") == [folder.id])
  }

  @Test func editingAndRemoving() throws {
    let lib = try MediaLibrary(root: root)
    let a = try lib.addFolder("A", section: "Histoires")
    let b = try lib.addFolder("B", section: "Histoires")
    let (t1, _) = try lib.importFile(try source("one.mp3"), into: .folder(a.id), media: TaggedMedia(cover: true))
    let (t2, _) = try lib.importFile(try source("two.mp3"), into: .folder(a.id), media: TaggedMedia())

    try lib.renameTrack(t1.id, to: "  Le   premier ")
    #expect(lib.track(t1.id)?.title == "Le premier")
    #expect(throws: MerlinError.self) { try lib.renameFolder(a.id, to: "   ") }
    try lib.setSection(b.id, to: "Documentaires")
    #expect(lib.folder(b.id)?.section == "Documentaires")
    #expect(lib.sections().contains("Documentaires"))

    try lib.moveTracks([t2.id], to: b.id)
    #expect(lib.tracks(in: b.id).map(\.id) == [t2.id])

    try lib.removeTracks([t2.id])
    #expect(lib.track(t2.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: lib.url(t2.audio).path))

    try lib.removeFolder(a.id)
    #expect(lib.track(t1.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: lib.url(t1.audio).path))
    #expect(!FileManager.default.fileExists(atPath: lib.url(t1.cover!).path))
    #expect(lib.folders().map(\.title) == ["B"])

    try lib.reorderFolders([b.id])
    #expect(lib.folder(b.id)?.position == 0)
  }

  @Test func syncTargetsSkipExcludedAndEmptyFolders() throws {
    let lib = try MediaLibrary(root: root)
    let a = try lib.addFolder("A", section: "Histoires")
    let b = try lib.addFolder("B", section: "Histoires")
    _ = try lib.addFolder("Empty", section: "Histoires")
    try lib.importFile(try source("one.mp3"), into: .folder(a.id), media: TaggedMedia())
    try lib.importFile(try source("two.mp3"), into: .folder(b.id), media: TaggedMedia())
    try lib.setIncluded(false, folders: [b.id], target: "speaker:1")
    #expect(lib.syncedFolders("speaker:1").map(\.0.title) == ["A"])
    #expect(lib.syncedFolders("speaker:2").map(\.0.title) == ["A", "B"])
    try lib.setIncluded(true, folders: [b.id], target: "speaker:1")
    #expect(lib.syncedFolders("speaker:1").count == 2)
  }

  @Test func scratchFilesAreCleanedUp() throws {
    let lib = try MediaLibrary(root: root)
    let leftover = lib.scratchURL("mp3")
    try Data("x".utf8).write(to: leftover)
    lib.cleanScratch()
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(MediaLibrary.databaseName).path))
  }

  @Test func audioFilesExpandsFolders() throws {
    let sub = dir.appendingPathComponent("music/b")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    for name in ["music/b/2.mp3", "music/1.FLAC", "music/notes.txt"] {
      try Data().write(to: dir.appendingPathComponent(name))
    }
    let found = try MediaLibrary.audioFiles([dir.appendingPathComponent("music")]).map(\.lastPathComponent)
    #expect(found == ["1.FLAC", "2.mp3"])
  }
}

// MARK: - Catalog

final class StubCatalog: CatalogSource {
  var contents: [String: JSONObject] = [:]
  var collections: [String: JSONObject] = [:]
  var files: [String: Data] = [:]
  var requests: [String] = []

  func content(_ id: String) throws -> JSONObject {
    requests.append("content \(id)")
    guard let c = contents[id] else { throw BackendError("404") }
    return c
  }

  func collection(_ id: String) throws -> JSONObject {
    requests.append("collection \(id)")
    guard let c = collections[id] else { throw BackendError("404") }
    return c
  }

  func download(_ url: String, to dest: URL, cancel: CancelToken?, progress: ((Int64, Int64) -> Void)?) throws {
    requests.append("download \(url)")
    guard let d = files[url] else { throw BackendError("HTTP 404") }
    progress?(Int64(d.count / 2), Int64(d.count))
    try d.write(to: dest)
  }
}

@Suite final class CatalogImporterTests {
  let dir = tempDir()
  deinit { try? FileManager.default.removeItem(at: dir) }

  func catalog() throws -> StubCatalog {
    let c = StubCatalog()
    let img = dir.appendingPathComponent("img.png")
    try solidImage(img, width: 200, height: 200, rgb: (1, 0, 0), png: true)
    c.files["https://img/col.png"] = try Data(contentsOf: img)
    c.files["https://img/ep.png"] = try Data(contentsOf: img)
    for i in 1...3 { c.files["https://audio/\(i).mp3"] = silentMP3(frames: 10 + i) }
    let episodes: [JSONObject] = (1...3).map { i in
      ["id": "c\(i)", "title": "Épisode \(i)", "episode": 4 - i, "duration": 600 + i, "author": "Bayard",
       "audio_url": "https://audio/\(i).mp3", "images": [["url": "https://img/ep.png"]]]
    }
    for e in episodes { c.contents[e.str("id")!] = e }
    c.collections["col"] = ["id": "col", "title": "Les Belles Histoires", "images": [["url": "https://img/col.png"]], "contents": episodes]
    c.contents["solo"] = ["id": "solo", "title": "Seul", "audio_url": "https://audio/1.mp3"]
    c.contents["paid"] = ["id": "paid", "title": "Payant", "audio_url": NSNull()]
    return c
  }

  static let locked = "https://secure.bayard.io/edition/audio/979/979_001_128k.mp3"

  @Test func lockedAudioIsRecognised() {
    #expect(CatalogFormat.isLocked(["audio_url": Self.locked]))
    #expect(!CatalogFormat.isLocked(["audio_url": Self.locked + "?Expires=1&Signature=x&Key-Pair-Id=K"]), "a signed link works")
    #expect(!CatalogFormat.isLocked(["audio_url": "https://bayard-static.s3.eu-west-1.amazonaws.com/a.mp3"]))
    #expect(!CatalogFormat.isLocked([:]))
  }

  @Test func lockedEpisodesAreSkippedWithoutDownloading() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let c = try catalog()
    var episodes = c.collections["col"]!.objs("contents")
    episodes[0]["audio_url"] = Self.locked
    c.collections["col"]!["contents"] = episodes
    let s = try CatalogImporter(library: lib, source: c).importCollection("col")
    #expect(s.added == 2 && s.failed.isEmpty)
    #expect(s.locked.map(\.id) == ["c1"], "left for PurchaseImporter")
    #expect(!c.requests.contains("download \(Self.locked)"))

    c.contents["c9"] = ["id": "c9", "title": "Artémis", "audio_url": Self.locked]
    #expect(throws: MerlinError.self) { try CatalogImporter(library: lib, source: c).importContent("c9") }
  }

  @Test func aFullyLockedCollectionIsHandedBackWithoutAFolder() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let c = try catalog()
    c.collections["sold"] = ["id": "sold", "title": "Le feuilleton d'Artémis", "contents": [["id": "a1", "title": "Introduction", "audio_url": Self.locked]]]
    let s = try CatalogImporter(library: lib, source: c).importCollection("sold")
    #expect(s.added == 0 && s.locked.map(\.id) == ["a1"])
    #expect(lib.merlinFolder(collection: "sold") == nil)
  }

  @Test func aCollectionBecomesAFolder() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let c = try catalog()
    let s = try CatalogImporter(library: lib, source: c).importCollection("col")
    #expect(s == CatalogImporter.CollectionSummary(added: 3, skipped: 0, failed: []))
    let folder = try #require(lib.merlinFolder(collection: "col"))
    #expect(folder.title == "Les Belles Histoires" && folder.source == .merlin && folder.cover == "\(folder.id).jpg")
    let tracks = lib.tracks(in: folder.id)
    #expect(tracks.map(\.title) == ["Épisode 3", "Épisode 2", "Épisode 1"]) // episode order
    #expect(tracks.map(\.episode) == [1, 2, 3])
    #expect(tracks[0].sourceID == "c3" && tracks[0].artist == "Bayard" && tracks[0].duration == 603)
    #expect(tracks.allSatisfy { $0.cover != nil && $0.size > 0 })
    #expect(lib.merlinContentIDs() == ["c1", "c2", "c3"])

    // Again: nothing downloaded twice.
    c.requests = []
    let again = try CatalogImporter(library: lib, source: c).importCollection("col")
    #expect(again.added == 0 && again.skipped == 3)
    #expect(c.requests == ["collection col"])
  }

  @Test func reportsBytesForTheProgressBar() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let c = try catalog()
    var cols = c.collections["col"]!
    cols["contents"] = cols.objs("contents").map { e -> JSONObject in
      var e = e
      e["fileSize"] = c.files[e.str("audio_url")!]!.count
      return e
    }
    c.collections["col"] = cols
    let total = (1...3).reduce(0) { $0 + c.files["https://audio/\($1).mp3"]!.count }
    let importer = CatalogImporter(library: lib, source: c)
    var expected: [Int64] = [], received: [Int64] = []
    importer.onExpect = { expected.append($0) }
    importer.onBytes = { r, _ in received.append(r) }
    _ = try importer.importCollection("col")
    #expect(expected == [Int64(total)])
    #expect(received == received.sorted(), "never goes backwards")
    #expect(received.last == Int64(total))
  }

  @Test func singleEpisodes() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let c = try catalog()
    let importer = CatalogImporter(library: lib, source: c)
    // An episode of a known collection goes to its folder.
    let folder = try importer.folder(collectionID: "col")
    #expect(try importer.importContent("c2", folder: folder.id) != .alreadyThere)
    #expect(lib.tracks(in: folder.id).map(\.sourceID) == ["c2"])
    #expect(try importer.importContent("c2") == .alreadyThere)
    // One without a collection goes to "Épisodes Merlin".
    try importer.importContent("solo")
    #expect(lib.folders().map(\.title) == ["Les Belles Histoires", "Épisodes Merlin"])
    // No audio: a clear error, nothing left behind.
    #expect(throws: MerlinError.self) { try importer.importContent("paid") }
    let names = try FileManager.default.contentsOfDirectory(atPath: lib.root.path).filter { $0.hasPrefix(".") }
    #expect(names.isEmpty)
  }
}

// MARK: - Speaker playlist

@Suite final class SpeakerPlaylistTests {
  let dir = tempDir()
  deinit { try? FileManager.default.removeItem(at: dir) }

  static let serverTree = """
  [{"uuid":"sec-h","title":"Histoires","child":[{"uuid":"f-old","title":"Old","child":[{"uuid":"t-old","title":"Old"}]}]},
   {"uuid":"sec-m","title":"Musique","child":[]},
   {"uuid":"fav","title":"Merlin_favorite","favorite":1,"child":[{"uuid":"t-old","title":"Old"}]}]
  """

  @Test func libraryFoldersGoIntoTheirSections() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let music = try lib.addFolder("Comptines", section: "musique")
    let stories = try lib.addFolder(String(repeating: "é", count: 40), section: "Inconnue") // unknown -> first section
    let skipped = try lib.addFolder("Pas pour l'enceinte", section: "Histoires")
    for (f, name) in [(music, "a.mp3"), (stories, "b.mp3"), (skipped, "c.mp3")] {
      let src = dir.appendingPathComponent(name)
      try silentMP3(frames: 5).write(to: src)
      try lib.importFile(src, into: .folder(f.id), media: TaggedMedia(cover: f.id == music.id))
    }
    try lib.setIncluded(false, folders: [skipped.id], target: SpeakerPlaylist.target("s1"))

    var plan: JSONObject = ["playlistText": Self.serverTree, "fileList": [
      ["type": "image", "filename": "sec-h.jpg", "url": "https://cdn/sec-h.jpg"],
      ["type": "image", "filename": "f-old.jpg", "url": "https://cdn/f-old.jpg"],
      ["type": "audio", "filename": "t-old.mp3", "url": "https://cdn/t-old.mp3"],
    ]]
    let covers = dir.appendingPathComponent("covers")
    let s = try SpeakerPlaylist(library: lib, settingID: "s1", coverDir: covers, media: TaggedMedia()).build(&plan)
    #expect(s == SpeakerPlaylist.Summary(folders: 2, tracks: 2))

    let tree = try JSON.parse(plan["playlistText"] as! String) as! [JSONObject]
    #expect(tree.map { $0.str("uuid") } == ["sec-h", "sec-m", "fav"])
    #expect(tree[2].objs("child").isEmpty, "favorites pointed at the server's episodes")
    let h = tree[0].objs("child"), m = tree[1].objs("child")
    #expect(h.map { $0.str("uuid") } == [stories.id])
    #expect(h[0].str("title")!.utf8.count == 63) // shortened like the server does
    #expect(m.map { $0.str("title") } == ["Comptines"])
    let track = m[0].objs("child")[0]
    #expect(track.keys.sorted() == ["add_time", "limit_time", "title", "type", "uuid"])

    let files = plan.objs("fileList")
    let names = files.compactMap { $0.str("filename") }
    #expect(names.contains("sec-h.jpg") && !names.contains("f-old.jpg") && !names.contains("t-old.mp3"))
    let trackID = try #require(track.str("uuid"))
    let audio = try #require(files.first { $0.str("filename") == "\(trackID).mp3" })
    #expect(audio.str("path") == lib.url(lib.track(trackID)!.audio).path)
    // 128x128 covers, made from the library's.
    let cover = try #require(files.first { $0.str("filename") == "\(trackID).jpg" }?.str("path"))
    let src = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: cover) as CFURL, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 128 && props[kCGImagePropertyPixelHeight] as? Int == 128)
    // A folder without a cover gets one with its name.
    let folderCover = try #require(files.first { $0.str("filename") == "\(stories.id).jpg" }?.str("path"))
    #expect(try String(contentsOfFile: folderCover, encoding: .utf8).hasPrefix("cover titled"))
    #expect(lib.sections().prefix(2) == ["Histoires", "Musique"])
  }

  @Test func aSpeakerWithoutSectionsGetsOne() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let f = try lib.addFolder("A", section: "Histoires")
    let src = dir.appendingPathComponent("a.mp3")
    try silentMP3(frames: 5).write(to: src)
    try lib.importFile(src, into: .folder(f.id), media: TaggedMedia())
    var plan: JSONObject = ["playlistText": "[]", "fileList": []]
    try SpeakerPlaylist(library: lib, settingID: "s1", coverDir: dir.appendingPathComponent("c"), media: TaggedMedia()).build(&plan)
    let tree = try JSON.parse(plan["playlistText"] as! String) as! [JSONObject]
    #expect(tree.map { $0.str("title") } == ["Histoires"])
    #expect(tree[0].objs("child").map { $0.str("title") } == ["A"])
  }

  @Test func titlesAreShortenedLikeTheServerDoes() {
    #expect(SpeakerPlaylist.title("  a   b ") == "a b")
    let t = SpeakerPlaylist.title(String(repeating: "é", count: 40)) // 80 bytes
    #expect(t.hasSuffix("...") && t.utf8.count == 63)
    #expect(SpeakerPlaylist.title("  ") == "Sans titre")
  }
}
