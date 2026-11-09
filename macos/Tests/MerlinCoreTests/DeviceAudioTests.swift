import Foundation
@testable import MerlinCore
import Testing

@Suite final class OriginalsAndDeviceCopiesTests {
  let dir = tempDir()
  deinit { try? FileManager.default.removeItem(at: dir) }

  func source(_ name: String, frames: Int = 20) throws -> URL {
    let u = dir.appendingPathComponent(name)
    try silentMP3(frames: frames).write(to: u)
    return u
  }

  @Test func importsKeepOriginalsAndConvertOnlyWhatMacOSCantPlay() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let media = TaggedMedia(bitRate: 320_000)
    let src = try source("loud.mp3", frames: 33)
    let (mp3, a1) = try lib.importFile(src, into: .byAlbum(section: "Musique"), media: media)
    #expect(a1 == .copied)
    #expect(try Data(contentsOf: lib.url(mp3.audio)) == Data(contentsOf: src), "the 320k MP3 is kept byte for byte")
    #expect(!mp3.speakerReady)

    let (m4a, a2) = try lib.importFile(try source("song.m4a"), into: .byAlbum(section: "Musique"), media: media)
    #expect(a2 == .copied && m4a.audio == "\(m4a.id).m4a")

    let (ogg, a3) = try lib.importFile(try source("song.ogg"), into: .byAlbum(section: "Musique"), media: media)
    #expect(a3 == .transcoded && ogg.audio == "\(ogg.id).mp3")
    #expect(media.log.value == ["256k song.ogg"])

    let (ready, _) = try lib.importFile(try source("ready.mp3"), into: .byAlbum(section: "Musique"), media: TaggedMedia())
    #expect(ready.speakerReady)
    #expect(lib.track(mp3.id)?.speakerReady == false, "persisted")
  }

  @Test func devicesGetCachedCopiesWhenTheyNeedThem() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let media = TaggedMedia(bitRate: 320_000)
    let (loud, _) = try lib.importFile(try source("loud.mp3"), into: .byAlbum(section: "Musique"), media: media)
    let (m4a, _) = try lib.importFile(try source("song.m4a"), into: .byAlbum(section: "Musique"), media: media)
    let (ready, _) = try lib.importFile(try source("ready.mp3"), into: .byAlbum(section: "Musique"), media: TaggedMedia())
    let tracks = [loud, m4a, ready].compactMap { lib.track($0.id) }
    let audio = DeviceAudio(library: lib, cacheDir: dir.appendingPathComponent("converted"), media: media)
    media.log.mutate { $0 = [] }

    // The speaker: everything but the speaker-ready MP3 is converted.
    let speaker = try audio.files(for: tracks, device: .speaker)
    #expect(speaker.converted == 2)
    #expect(speaker.files[ready.id] == lib.url(ready.audio))
    #expect(speaker.files[loud.id]?.path.hasSuffix("converted/speaker/\(loud.id).mp3") == true)
    #expect(Set(media.log.value) == ["speaker \(loud.audio)", "speaker \(m4a.audio)"])

    // Cached: nothing converted the second time.
    media.log.mutate { $0 = [] }
    #expect(try audio.files(for: tracks, device: .speaker).converted == 0)
    #expect(media.log.value.isEmpty)

    // The iPod: only the non-MP3.
    let ipod = try audio.files(for: tracks, device: .ipod)
    #expect(ipod.converted == 1)
    #expect(ipod.files[loud.id] == lib.url(loud.audio))
    #expect(ipod.files[m4a.id]?.lastPathComponent == "\(m4a.id).mp3")

    // Copies of deleted tracks go.
    try lib.removeTracks([m4a.id])
    audio.prune(keeping: Set(lib.allTracks().map(\.id)))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("converted/speaker/\(m4a.id).mp3").path))
  }

  @Test func theSpeakerPlaylistSendsTheConvertedCopy() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let media = TaggedMedia(bitRate: 320_000)
    let (loud, _) = try lib.importFile(try source("loud.mp3"), into: .byAlbum(section: "Musique"), media: media)
    var plan: JSONObject = ["playlistText": #"[{"uuid":"s","title":"Musique","child":[]}]"#, "fileList": []]
    var said: [String] = []
    try SpeakerPlaylist(library: lib, settingID: "s1", coverDir: dir.appendingPathComponent("covers"),
                        convertedDir: dir.appendingPathComponent("converted"), media: media).build(&plan) { said.append($0) }
    let audio = try #require(plan.objs("fileList").first { $0.str("type") == "audio" })
    #expect(audio.str("filename") == "\(loud.id).mp3")
    #expect(audio.str("path") == dir.appendingPathComponent("converted/speaker/\(loud.id).mp3").path)
    #expect(said.first == "Converting 1 file(s) to MP3 for the speaker…")
  }

  @Test func theIPodGetsMP3s() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let media = TaggedMedia()
    let (m4a, _) = try lib.importFile(try source("song.m4a"), into: .byAlbum(section: "Musique"), media: media)
    // Without a cache folder, non-MP3s are left out; with one, they're converted.
    #expect(try IPodContent.build(library: lib, target: "ipod:x").missing == [m4a.title])
    let content = try IPodContent.build(library: lib, target: "ipod:x", converted: dir.appendingPathComponent("converted"))
    #expect(content.items.first?.source.lastPathComponent == "\(m4a.id).mp3")
    #expect(content.missing.isEmpty)
  }

  @Test func librariesFromVersion1AreUpgraded() throws {
    let root = dir.appendingPathComponent("old")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = try SQLite(url: root.appendingPathComponent(MediaLibrary.databaseName))
    try db.exec("""
      CREATE TABLE folders (id TEXT PRIMARY KEY, title TEXT NOT NULL, section TEXT NOT NULL, cover TEXT, source TEXT NOT NULL,
        source_id TEXT, position INTEGER NOT NULL, added_at INTEGER NOT NULL);
      CREATE TABLE tracks (id TEXT PRIMARY KEY, folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE, title TEXT NOT NULL,
        artist TEXT, episode INTEGER, position INTEGER NOT NULL, duration INTEGER, audio TEXT NOT NULL, size INTEGER NOT NULL,
        cover TEXT, source TEXT NOT NULL, source_id TEXT, source_name TEXT, added_at INTEGER NOT NULL);
      CREATE TABLE sync_exclusions (target TEXT NOT NULL, folder_id TEXT NOT NULL, PRIMARY KEY (target, folder_id));
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
      INSERT INTO folders VALUES ('f', 'F', 'Histoires', NULL, 'file', NULL, 0, 0);
      INSERT INTO tracks VALUES ('t', 'f', 'T', NULL, NULL, 0, 60, 't.mp3', 1, NULL, 'file', NULL, NULL, 0);
      PRAGMA user_version = 1;
      """)
    let lib = try MediaLibrary(root: root)
    #expect(lib.track("t")?.speakerReady == true)
    #expect(lib.db.userVersion == 2)
    #expect(lib.tracksWithoutEmbeddedArtwork() == ["t"], "a v1 library still gets the one-time cover pass")
  }
}
