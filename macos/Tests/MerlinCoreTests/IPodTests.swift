import Foundation
@testable import MerlinCore
import Testing

/// A silent MP3 (MPEG-1 layer III, 128 kbit/s, 44.1 kHz): 417-byte frames
/// of 1152 samples.
func silentMP3(frames: Int) -> Data {
  var frame = [UInt8](repeating: 0, count: 417)
  frame[0] = 0xFF; frame[1] = 0xFB; frame[2] = 0x90; frame[3] = 0x00
  return Data((0..<frames).flatMap { _ in frame })
}

func track(_ title: String, album: String = "Album", artist: String = "Artist", dbid: UInt64, path: String = ":iPod_Control:Music:F00:X.mp3") -> ITunesTrack {
  ITunesTrack(title: title, album: album, artist: artist, genre: "Merlin", trackNumber: 1, trackCount: 1,
              size: 1000, durationMS: 2000, bitrate: 128, sampleRate: 44100, ipodPath: path, dbid: dbid)
}

@Suite struct ITunesDBTests {
  /// Writes, reads back, writes again: same bytes.
  func roundTrip(_ db: ITunesDB) throws -> ITunesDB {
    let data = db.data()
    let again = try ITunesDB(data: data)
    #expect(again.data() == data)
    return again
  }

  @Test func newDatabaseHasAnEmptyMasterPlaylist() throws {
    let db = try roundTrip(ITunesDB(name: "Lou's iPod"))
    #expect(db.name == "Lou's iPod")
    #expect(db.trackCount == 0)
    #expect(db.data().count > 244)
  }

  @Test func addsTracksPlaylistsAndIndexes() throws {
    let db = ITunesDB(name: "iPod")
    db.replace(tracks: [track("Le loup", album: "Contes", artist: "Histoires", dbid: 1),
                        track("Zébulon", album: "Contes", artist: "Histoires", dbid: 2),
                        track("Abracadabra", album: "Comptines", artist: "Musique", dbid: 3)],
               removing: [], playlists: [ITunesPlaylist(name: "Contes", id: 99, trackDBIDs: [1, 2])], removingPlaylists: [])
    let back = try roundTrip(db)
    #expect(back.trackCount == 3)
    #expect(back.trackTitle(dbid: 2) == "Zébulon")
    #expect(back.trackString(dbid: 1, MHOD.album) == "Contes")
    #expect(back.trackString(dbid: 1, MHOD.artist) == "Histoires")
    #expect(back.trackPath(dbid: 3) == ":iPod_Control:Music:F00:X.mp3")
    #expect(back.playlistNames == ["Contes"])
    #expect(back.playlistTrackIDs(named: "Contes") == [back.trackID(dbid: 1), back.trackID(dbid: 2)].compactMap { $0 })
    #expect(back.trackID(dbid: 1) == 52) // libgpod's first id

    // Master playlist: every track, five sort indexes + jump tables.
    let mpl = try #require(back.masterPlaylist)
    #expect(mpl.children.filter { $0.tag == "mhip" }.count == 3)
    let indexes = mpl.children.filter { $0.tag == "mhod" && $0.type == MHOD.libraryIndex }
    #expect(indexes.count == 5)
    let byTitle = try #require(indexes.first { Bytes.u32($0.payload, 0) == 0x03 })
    let order = (0..<3).map { Bytes.u32(byTitle.payload, 48 + 4 * $0) }
    #expect(order == [2, 0, 1]) // Abracadabra, Le loup, Zébulon
    let jumps = try #require(mpl.children.first { $0.tag == "mhod" && $0.type == MHOD.jumpTable && Bytes.u32($0.payload, 0) == 0x03 })
    #expect(Bytes.u32(jumps.payload, 4) == 3) // A, L, Z

    // Albums and artists lists.
    #expect(back.albumList?.children.count == 2)
    #expect(back.artistList?.children.count == 2)
    #expect(Bytes.u32(mpl.header, 16) == 3)
  }

  @Test func replacingKeepsOtherRecordsByteForByte() throws {
    let db = ITunesDB(name: "iPod")
    db.replace(tracks: [track("Owner's song", dbid: 7)], removing: [],
               playlists: [ITunesPlaylist(name: "Owner's list", id: 5, trackDBIDs: [7])], removingPlaylists: [])
    let before = try ITunesDB(data: db.data())
    let owned = try #require(before.track(dbid: 7)).bytes

    before.replace(tracks: [track("Merlin 1", dbid: 100), track("Merlin 2", dbid: 101)], removing: [],
                   playlists: [ITunesPlaylist(name: "Merlin", id: 6, trackDBIDs: [100, 101])], removingPlaylists: [])
    let added = try roundTrip(before)
    #expect(added.track(dbid: 7)?.bytes == owned)
    #expect(added.playlistNames == ["Owner's list", "Merlin"])

    // Next time: one Merlin track goes, the other is rewritten.
    added.replace(tracks: [track("Merlin 2 renamed", dbid: 101)], removing: [100, 101],
                  playlists: [ITunesPlaylist(name: "Merlin", id: 6, trackDBIDs: [101])], removingPlaylists: [6])
    let after = try roundTrip(added)
    #expect(after.track(dbid: 7)?.bytes == owned)
    #expect(after.trackCount == 2)
    #expect(after.trackTitle(dbid: 101) == "Merlin 2 renamed")
    #expect(after.trackID(dbid: 101) == before.trackID(dbid: 101)) // kept its id
    #expect(after.track(dbid: 100) == nil)
    #expect(after.playlistNames == ["Owner's list", "Merlin"])
    #expect(after.masterPlaylist?.children.filter { $0.tag == "mhip" }.count == 2)
  }

  @Test func removedTracksLeaveTheOwnersPlaylists() throws {
    let db = ITunesDB(name: "iPod")
    db.replace(tracks: [track("Mine", dbid: 1), track("Merlin", dbid: 2)], removing: [],
               playlists: [ITunesPlaylist(name: "Mix", id: 5, trackDBIDs: [1, 2])], removingPlaylists: [])
    db.replace(tracks: [], removing: [2], playlists: [], removingPlaylists: [])
    let back = try roundTrip(db)
    #expect(back.playlistTrackIDs(named: "Mix") == [back.trackID(dbid: 1)!])
    #expect(back.albumList?.children.count == 1)
  }

  @Test func playCountsAreMerged() throws {
    let db = ITunesDB(name: "iPod")
    db.replace(tracks: [track("A", dbid: 1), track("B", dbid: 2)], removing: [], playlists: [], removingPlaylists: [])
    var w = ByteWriter()
    w.tag("mhdp"); w.u32(0x60); w.u32(0x1C); w.u32(2); w.zeros32(20)
    w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)         // A: nothing
    w.u32(3); w.u32(123_456); w.u32(42_000); w.u32(80); w.u32(0); w.u32(1); w.u32(0) // B
    try db.applyPlayCounts(Data(w.bytes))
    let b = try #require(db.track(dbid: 2))
    #expect(b.u32(0x50) == 3)
    #expect(b.u32(0x58) == 123_456)
    #expect(b.u32(0x6C) == 42_000)
    #expect(b.u8(0x1F) == 80)
    #expect(b.u32(0x9C) == 1)
    #expect(db.track(dbid: 1)?.u32(0x50) == 0)

    // Rewriting a track keeps them.
    db.replace(tracks: [track("B again", dbid: 2)], removing: [2], playlists: [], removingPlaylists: [])
    #expect(db.track(dbid: 2)?.u32(0x50) == 3)
    #expect(db.track(dbid: 2)?.u32(0x6C) == 42_000)
  }

  @Test func onTheGoPlaylistsPointAtPositions() throws {
    let db = ITunesDB(name: "iPod")
    db.replace(tracks: [track("A", dbid: 10), track("B", dbid: 20)], removing: [], playlists: [], removingPlaylists: [])
    var w = ByteWriter()
    w.tag("mhpo"); w.u32(0x14); w.u32(4); w.u32(2); w.u32(0)
    w.u32(1); w.u32(0)
    #expect(try db.onTheGoTracks(Data(w.bytes)) == [20, 10])
  }

  @Test func hash58FillsTheHeaderOnly() throws {
    var data = ITunesDB(name: "iPod").data()
    let original = data
    try ITunesDB.writeHash58(&data, firewireID: [0x00, 0x0A, 0x27, 0x00, 0x1B, 0x2C, 0x3D, 0x4E])
    #expect(data.count == original.count)
    #expect(data[0x30] == 1)
    #expect(data[0x58..<0x6C].contains { $0 != 0 })
    #expect(data[0..<0x30] == original[0..<0x30])
    #expect(data[0x6C...] == original[0x6C...])
    // Deterministic, and depends on the GUID.
    var again = original
    try ITunesDB.writeHash58(&again, firewireID: [0x00, 0x0A, 0x27, 0x00, 0x1B, 0x2C, 0x3D, 0x4E])
    #expect(again == data)
    var other = original
    try ITunesDB.writeHash58(&other, firewireID: [0x00, 0x0A, 0x27, 0x00, 0x1B, 0x2C, 0x3D, 0x4F])
    #expect(other[0x58..<0x6C] != data[0x58..<0x6C])
    _ = try ITunesDB(data: data)
  }

  @Test func rejectsGarbage() {
    #expect(throws: ITunesDBError.self) { try ITunesDB(data: Data("hello world, not a db".utf8)) }
    var truncated = ITunesDB(name: "x").data()
    truncated.removeLast(10)
    #expect(throws: ITunesDBError.self) { try ITunesDB(data: truncated) }
  }
}

@Suite final class IPodTransferTests {
  let dir = tempDir()
  lazy var mount = dir.appendingPathComponent("IPOD")

  deinit { try? FileManager.default.removeItem(at: dir) }

  static let target = "ipod:test"

  /// Histoires: Les Belles Histoires (t1, t2, t3 whose file is gone),
  /// Comptines (t4); Musique: Comptines (t5).
  func library() throws -> MediaLibrary {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("Library"))
    let belles = try lib.addFolder("Les Belles Histoires", section: "Histoires")
    let c1 = try lib.addFolder("Comptines", section: "Histoires")
    let c2 = try lib.addFolder("Comptines", section: "Musique")
    for (id, title, folder) in [("t1", "Monsieur Loup", belles), ("t2", "Le Chat", belles), ("t3", "Pas téléchargé", belles),
                                ("t4", "Une souris verte", c1), ("t5", "Frère Jacques", c2)] {
      let src = lib.scratchURL("mp3")
      try silentMP3(frames: 40 + Int(String(id.last!))!).write(to: src)
      _ = try lib.insertTrack(id: id, folderID: folder.id, title: title, artist: nil, episode: nil, duration: nil,
                              audio: src, cover: nil, source: .file, sourceID: nil, sourceName: nil)
    }
    try FileManager.default.removeItem(at: lib.url("t3.mp3"))
    return lib
  }

  func device() throws -> IPodDevice {
    try FileManager.default.createDirectory(at: mount.appendingPathComponent("iPod_Control/iTunes"), withIntermediateDirectories: true)
    return try #require(IPodDevice(mountPoint: mount))
  }

  @Test func audioFactsOfAnMP3() throws {
    let url = dir.appendingPathComponent("a.mp3")
    try silentMP3(frames: 100).write(to: url)
    let facts = try AudioFacts.read(url)
    #expect(facts.sampleRate == 44100)
    #expect(facts.bitrate == 128)
    #expect(abs(facts.durationMS - 2612) < 60)
  }

  @Test func contentFollowsTheLibrary() throws {
    let lib = try library()
    let content = try IPodContent.build(library: lib, target: Self.target)
    #expect(content.items.map(\.title) == ["Monsieur Loup", "Le Chat", "Une souris verte", "Frère Jacques"])
    #expect(content.missing == ["Pas téléchargé"])
    let loup = content.items[0]
    #expect(loup.album == "Les Belles Histoires" && loup.artist == "Histoires")
    #expect(loup.trackNumber == 1 && loup.trackCount == 3)
    #expect(content.folders.map(\.name) == ["Les Belles Histoires", "Comptines (Histoires)", "Comptines (Musique)"])
  }

  @Test func transferThenUpdateThenRemove() throws {
    let ipod = try device()
    let out = Captured()
    // An owner's song already on the iPod.
    let owner = ITunesDB(name: "Lou's iPod")
    owner.replace(tracks: [track("Owner's song", dbid: 7, path: ":iPod_Control:Music:F00:OWNR.mp3")], removing: [],
                  playlists: [], removingPlaylists: [])
    try owner.data().write(to: ipod.databaseURL)
    var w = ByteWriter() // the iPod played the owner's song twice
    w.tag("mhdp"); w.u32(0x60); w.u32(0x10); w.u32(1); w.zeros32(20); w.u32(2); w.u32(0); w.u32(0); w.u32(0)
    try Data(w.bytes).write(to: ipod.itunesDir.appendingPathComponent("Play Counts"))

    let transfer = IPodTransfer(device: ipod, out: out)
    let lib = try library()
    let content = try IPodContent.build(library: lib, target: Self.target)
    let first = try transfer.run(content)
    #expect(first == IPodTransfer.Summary(copied: 4, kept: 0, removed: 0, playlists: 3))

    var db = try ITunesDB(data: Data(contentsOf: ipod.databaseURL))
    #expect(db.trackCount == 5)
    #expect(db.name == "Lou's iPod")
    #expect(db.playlistNames == ["Les Belles Histoires", "Comptines (Histoires)", "Comptines (Musique)"])
    #expect(db.track(dbid: 7)?.u32(0x50) == 2) // play counts merged...
    #expect(!FileManager.default.fileExists(atPath: ipod.itunesDir.appendingPathComponent("Play Counts").path)) // ...and consumed
    #expect(FileManager.default.fileExists(atPath: ipod.itunesDir.appendingPathComponent("iTunesDB.before-merlin").path))
    let manifest = transfer.loadManifest()
    #expect(manifest.tracks.count == 4)
    for t in manifest.tracks.values {
      #expect(IPodTransfer.size(transfer.fileURL(t.path)) > 0)
      #expect(db.trackPath(dbid: t.dbid) == t.path)
    }
    let loup = try #require(manifest.tracks["t1"])
    #expect(db.trackTitle(dbid: loup.dbid) == "Monsieur Loup")
    #expect(db.trackString(dbid: loup.dbid, MHOD.genre) == "Merlin")
    #expect(transfer.merlinTrackCount() == 4)

    // "Le Chat" left the library; everything else is already there.
    try lib.removeTracks(["t2"])
    let second = try transfer.run(try IPodContent.build(library: lib, target: Self.target))
    #expect(second == IPodTransfer.Summary(copied: 0, kept: 3, removed: 1, playlists: 3))
    db = try ITunesDB(data: Data(contentsOf: ipod.databaseURL))
    #expect(db.trackCount == 4)
    let chat = try #require(manifest.tracks["t2"])
    #expect(!FileManager.default.fileExists(atPath: transfer.fileURL(chat.path).path))
    #expect(db.trackTitle(dbid: 7) == "Owner's song")

    // Remove everything Merlin put there.
    #expect(try transfer.removeAll() == 3)
    db = try ITunesDB(data: Data(contentsOf: ipod.databaseURL))
    #expect(db.trackCount == 1)
    #expect(db.playlistNames.isEmpty)
    #expect(db.albumList?.children.count == 1)
    for t in manifest.tracks.values { #expect(!FileManager.default.fileExists(atPath: transfer.fileURL(t.path).path)) }
  }

  @Test func aStrayITunesSDDoesNotMakeAVideoAShuffle() throws {
    let ipod = try device()
    try Data(count: 104).write(to: ipod.itunesDir.appendingPathComponent("iTunesSD"))
    let deviceDir = ipod.control.appendingPathComponent("Device")
    try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
    try "ModelNumStr: xA444\n".write(to: deviceDir.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
    let video = try #require(IPodDevice(mountPoint: mount))
    #expect(video.generation == .video2)
    #expect(video.problem(existing: nil) == nil)
    try IPodTransfer(device: video, out: Captured()).run(IPodContent())

    try "ModelNumStr: xA546\n".write(to: deviceDir.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
    #expect(try #require(IPodDevice(mountPoint: mount)).problem(existing: nil) != nil, "a real shuffle is still refused")
  }

  @Test func refusesAShuffle() throws {
    let ipod = try device()
    try Data().write(to: ipod.itunesDir.appendingPathComponent("iTunesSD"))
    #expect(throws: MerlinError.self) { try IPodTransfer(device: ipod, out: Captured()).run(IPodContent()) }
  }

  @Test func createsADatabaseOnAFreshIPod() throws {
    let ipod = try device()
    try IPodTransfer(device: ipod, out: Captured()).run(try IPodContent.build(library: library(), target: Self.target))
    let db = try ITunesDB(data: Data(contentsOf: ipod.databaseURL))
    #expect(db.trackCount == 4)
    #expect(db.name == ipod.volumeName)
    #expect(FileManager.default.fileExists(atPath: ipod.musicDir.appendingPathComponent("F19").path))
  }

  @Test func modelsAndFirewireID() throws {
    let ipod = try device()
    let deviceDir = ipod.control.appendingPathComponent("Device")
    try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
    try "ModelNumStr: xB029\nFirewireGuid: 0x000A27001B2C3D4E\n".write(to: deviceDir.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
    let classic = try #require(IPodDevice(mountPoint: mount))
    #expect(classic.generation == .classic1)
    #expect(classic.modelName == "iPod classic, 80 GB")
    #expect(classic.firewireID == [0x00, 0x0A, 0x27, 0x00, 0x1B, 0x2C, 0x3D, 0x4E])
    #expect(classic.checksum(existing: nil) == .hash58)
    #expect(classic.problem(existing: nil) == nil)

    try "ModelNumStr: MA147\n".write(to: deviceDir.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
    let video = try #require(IPodDevice(mountPoint: mount))
    #expect(video.generation == .video1)
    #expect(video.checksum(existing: nil) == .none)

    try "ModelNumStr: xC027\n".write(to: deviceDir.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
    let nano5 = try #require(IPodDevice(mountPoint: mount))
    #expect(nano5.problem(existing: nil) != nil)
  }
}
