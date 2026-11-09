import CryptoKit
import Foundation

// The iPod's music database (iPod_Control/iTunes/iTunesDB), ported from
// libgpod (itdb_itunesdb.c, itdb_hash58.c) — the library Amarok uses for
// iPods. Unlike libgpod, which rebuilds every record from its own model,
// records we don't need to change (the owner's tracks, playlists, smart
// playlists, albums...) are kept byte for byte: only Merlin's tracks and
// playlists, the master playlist's indexes and the album/artist lists are
// regenerated. That way nothing iTunes wrote and we don't understand is lost.
//
// Layout: little-endian chunks "mhXX" with a header length at +4 and either
// a total length (records) or a child count (lists: mhlt, mhlp, mhla, mhli)
// at +8.
//
//   mhbd                      database
//     mhsd type 1 > mhlt      tracks:     mhit > mhod (title, path, ...)
//     mhsd type 3 > mhlp      playlists (podcast-grouped copy)
//     mhsd type 2 > mhlp      playlists:  mhyp > mhod..., mhip > mhod 100
//     mhsd type 4 > mhla      albums:     mhia > mhod 200/201
//     mhsd type 8 > mhli      artists:    mhii > mhod 300
//     mhsd 5, 6, 10, ...      kept as is

public struct ITunesDBError: Error, CustomStringConvertible {
  public let description: String
  init(_ d: String) { description = d }
}

/// One chunk, its raw header and either parsed children or raw bytes.
final class Atom {
  var tag: String
  var header: [UInt8]
  var children: [Atom]
  /// Bytes after the header (and after the children) that aren't parsed.
  var payload: [UInt8]

  init(tag: String, header: [UInt8], children: [Atom] = [], payload: [UInt8] = []) {
    self.tag = tag
    self.header = header
    self.children = children
    self.payload = payload
  }

  /// Lists (a child count at +8, no length), in the iTunesDB and the ArtworkDB.
  static let lists: Set<String> = ["mhlt", "mhlp", "mhla", "mhli", "mhlf"]
  var isList: Bool { Self.lists.contains(tag) }

  func u8(_ o: Int) -> UInt8 { o < header.count ? header[o] : 0 }
  func u16(_ o: Int) -> UInt16 { o + 2 <= header.count ? Bytes.u16(header, o) : 0 }
  func u32(_ o: Int) -> UInt32 { o + 4 <= header.count ? Bytes.u32(header, o) : 0 }
  func u64(_ o: Int) -> UInt64 { o + 8 <= header.count ? Bytes.u64(header, o) : 0 }
  func set8(_ o: Int, _ v: UInt8) { if o < header.count { header[o] = v } }
  func set16(_ o: Int, _ v: UInt16) { if o + 2 <= header.count { Bytes.put16(&header, o, v) } }
  func set32(_ o: Int, _ v: UInt32) { if o + 4 <= header.count { Bytes.put32(&header, o, v) } }
  func set64(_ o: Int, _ v: UInt64) { if o + 8 <= header.count { Bytes.put64(&header, o, v) } }

  /// mhsd type / mhod type.
  var type: UInt32 { u32(12) }

  func serialize(into out: inout [UInt8]) {
    let start = out.count
    out += header
    for c in children { c.serialize(into: &out) }
    out += payload
    Bytes.put32(&out, start + 8, UInt32(isList ? children.count : out.count - start))
  }

  var bytes: [UInt8] {
    var out: [UInt8] = []
    serialize(into: &out)
    return out
  }
}

enum Bytes {
  static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
  static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
  }
  static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }
  static func put16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
    b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8(v >> 8)
  }
  static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    for i in 0..<4 { b[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
  }
  static func put64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
    put32(&b, o, UInt32(v & 0xFFFF_FFFF)); put32(&b, o + 4, UInt32(v >> 32))
  }
}

/// Appends little-endian fields, like libgpod's put32lint & co.
struct ByteWriter {
  var bytes: [UInt8] = []
  mutating func tag(_ s: String) { bytes += Array(s.utf8) }
  mutating func u8(_ v: UInt8) { bytes.append(v) }
  mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
  mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
  mutating func i32(_ v: Int) { u32(UInt32(truncatingIfNeeded: v)) }
  mutating func u64(_ v: UInt64) { u32(UInt32(v & 0xFFFF_FFFF)); u32(UInt32(v >> 32)) }
  mutating func f32(_ v: Float) { u32(v.bitPattern) }
  mutating func zeros32(_ n: Int) { bytes += [UInt8](repeating: 0, count: 4 * n) }
  mutating func zeros16(_ n: Int) { bytes += [UInt8](repeating: 0, count: 2 * n) }
}

// MARK: - Parsing

enum AtomParser {
  static func parse(_ data: [UInt8], root: String = "mhbd") throws -> Atom {
    guard data.count >= 12, tag(data, 0) == root else {
      if root != "mhbd" { throw ITunesDBError("not an ArtworkDB (missing \(root) header)") }
      throw ITunesDBError(data.starts(with: Array("dbhm".utf8))
        ? "this iPod's database is big-endian (not an iPod Merlin supports)"
        : "not an iTunesDB (missing mhbd header)")
    }
    let (root, _) = try atom(data, at: 0, limit: data.count)
    return root
  }

  static func tag(_ d: [UInt8], _ o: Int) -> String {
    String(decoding: d[o..<o + 4], as: UTF8.self)
  }

  private static func atom(_ d: [UInt8], at o: Int, limit: Int) throws -> (Atom, Int) {
    guard o + 12 <= limit else { throw corrupt("truncated chunk", o) }
    let tag = tag(d, o)
    guard tag.hasPrefix("mh") else { throw corrupt("unexpected data \"\(tag)\"", o) }
    let hlen = Int(Bytes.u32(d, o + 4))
    guard hlen >= 12, o + hlen <= limit else { throw corrupt("bad \(tag) header length \(hlen)", o) }
    let header = Array(d[o..<o + hlen])
    let atom = Atom(tag: tag, header: header)

    if Atom.lists.contains(tag) {
      // A list has no length of its own: its items follow the header.
      let count = Int(Bytes.u32(d, o + 8))
      var p = o + hlen
      for _ in 0..<count {
        let (child, next) = try self.atom(d, at: p, limit: limit)
        atom.children.append(child)
        p = next
      }
      return (atom, p)
    }

    let total = Int(Bytes.u32(d, o + 8))
    guard total >= hlen, o + total <= limit else { throw corrupt("bad \(tag) length \(total)", o) }
    let end = o + total
    switch tag {
    case "mhbd", "mhit", "mhyp", "mhip", "mhia", "mhii", "mhfd":
      var p = o + hlen
      while p + 12 <= end, d[p] == 0x6D, d[p + 1] == 0x68 { // "mh"
        let (child, next) = try self.atom(d, at: p, limit: end)
        atom.children.append(child)
        p = next
      }
      atom.payload = Array(d[p..<end])
    case "mhsd":
      var p = o + hlen
      if p + 12 <= end, Atom.lists.contains(self.tag(d, p)) {
        let (list, next) = try self.atom(d, at: p, limit: end)
        atom.children = [list]
        p = next
      }
      atom.payload = Array(d[p..<end])
    default: // mhod and anything unknown: opaque
      atom.payload = Array(d[(o + hlen)..<end])
    }
    return (atom, end)
  }

  private static func corrupt(_ what: String, _ offset: Int) -> ITunesDBError {
    ITunesDBError("iTunesDB looks damaged (\(what) at byte \(offset))")
  }
}

// MARK: - Records

enum MHOD {
  static let title: UInt32 = 1, path: UInt32 = 2, album: UInt32 = 3, artist: UInt32 = 4, genre: UInt32 = 5
  static let filetype: UInt32 = 6, composer: UInt32 = 12, albumArtist: UInt32 = 22
  static let sortArtist: UInt32 = 23, sortTitle: UInt32 = 27, sortAlbum: UInt32 = 28, sortComposer: UInt32 = 30
  static let libraryIndex: UInt32 = 52, jumpTable: UInt32 = 53, playlist: UInt32 = 100
  static let albumAlbum: UInt32 = 200, albumArtistName: UInt32 = 201, artistName: UInt32 = 300

  /// String types use a 16-byte sub-header: encoding (1 = UTF-16LE,
  /// 2 = UTF-8), byte length, two unknowns.
  static func string(_ type: UInt32, _ value: String) -> Atom {
    let utf16 = Array(value.utf16)
    var w = ByteWriter()
    w.tag("mhod"); w.u32(24); w.u32(UInt32(2 * utf16.count + 40)); w.u32(type); w.zeros32(2)
    var p = ByteWriter()
    p.u32(1); p.u32(UInt32(2 * utf16.count)); p.u32(1); p.u32(0)
    for unit in utf16 { p.u16(unit) }
    return Atom(tag: "mhod", header: w.bytes, payload: p.bytes)
  }

  static func stringValue(_ a: Atom) -> String? {
    guard a.tag == "mhod", a.payload.count >= 16 else { return nil }
    let encoding = Bytes.u32(a.payload, 0)
    let length = min(Int(Bytes.u32(a.payload, 4)), a.payload.count - 16)
    guard length >= 0 else { return nil }
    let raw = a.payload[16..<(16 + length)]
    if encoding == 2 { return String(decoding: raw, as: UTF8.self) }
    var units: [UInt16] = []
    var i = raw.startIndex
    while i + 1 < raw.endIndex {
      units.append(UInt16(raw[i]) | UInt16(raw[i + 1]) << 8)
      i += 2
    }
    return String(decoding: units, as: UTF16.self)
  }

  /// The position mhod that follows each playlist item.
  static func position(_ pos: Int) -> Atom {
    var w = ByteWriter()
    w.tag("mhod"); w.u32(24); w.u32(44); w.u32(playlist); w.zeros32(2)
    var p = ByteWriter()
    p.u32(UInt32(pos)); p.zeros32(4)
    return Atom(tag: "mhod", header: w.bytes, payload: p.bytes)
  }

  /// libgpod's hard-coded playlist preferences mhod (iTunes shows nothing
  /// without it).
  static func playlistPrefs() -> Atom {
    var w = ByteWriter()
    w.tag("mhod"); w.u32(0x18); w.u32(0x288); w.u32(playlist); w.zeros32(2)
    var p = ByteWriter()
    p.zeros32(4)
    for v: UInt32 in [0x010084, 0x05, 0x09, 0x03, 0x120001] { p.u32(v) }
    p.zeros32(3); p.u32(0xc80002); p.zeros32(3); p.u32(0x3c000d); p.zeros32(3); p.u32(0x7d0004)
    p.zeros32(3); p.u32(0x7d0003); p.zeros32(3); p.u32(0x640008); p.zeros32(3); p.u32(0x640017)
    p.u32(1); p.zeros32(2); p.u32(0x500014); p.u32(1); p.zeros32(2); p.u32(0x7d0015); p.u32(1)
    p.zeros32(114)
    return Atom(tag: "mhod", header: w.bytes, payload: p.bytes)
  }
}

extension Atom {
  func string(_ type: UInt32) -> String? {
    children.first { $0.tag == "mhod" && $0.type == type }.flatMap(MHOD.stringValue)
  }

  // mhit fields (offsets from libgpod's mk_mhit)
  var trackID: UInt32 { u32(0x10) }
  var dbid: UInt64 { u64(0x70) }
  var trackNumber: UInt32 { u32(0x2C) }
  var discNumber: UInt32 { u32(0x5C) }
  var albumID: UInt32 { u32(0x120) }
  var artistID: UInt32 { u32(0x1E0) }

  // mhyp fields
  var isMaster: Bool { tag == "mhyp" && u8(20) == 1 }
  var playlistID: UInt64 { u64(28) }
  /// mhip: the track it points to.
  var itemTrackID: UInt32 { u32(24) }
  // mhia / mhii
  var itemID: UInt32 { u32(0x10) }
}

/// What a Merlin track looks like in the database.
public struct ITunesTrack: Equatable {
  public var title: String
  public var album: String
  public var artist: String
  public var genre: String
  public var trackNumber: Int
  public var trackCount: Int
  public var size: Int
  public var durationMS: Int
  public var bitrate: Int // kbit/s
  public var sampleRate: Int
  /// ":iPod_Control:Music:F03:ABCD.mp3"
  public var ipodPath: String
  public var dbid: UInt64

  public init(title: String, album: String, artist: String, genre: String, trackNumber: Int, trackCount: Int,
              size: Int, durationMS: Int, bitrate: Int, sampleRate: Int, ipodPath: String, dbid: UInt64) {
    self.title = title
    self.album = album
    self.artist = artist
    self.genre = genre
    self.trackNumber = trackNumber
    self.trackCount = trackCount
    self.size = size
    self.durationMS = durationMS
    self.bitrate = bitrate
    self.sampleRate = sampleRate
    self.ipodPath = ipodPath
    self.dbid = dbid
  }
}

/// A playlist to write: a name and track dbids in order.
public struct ITunesPlaylist: Equatable {
  public var name: String
  public var id: UInt64
  public var trackDBIDs: [UInt64]
  public init(name: String, id: UInt64, trackDBIDs: [UInt64]) {
    self.name = name
    self.id = id
    self.trackDBIDs = trackDBIDs
  }
}

/// Seconds since 1904 in local time, the iPod's clock.
func macTime(_ date: Date = Date()) -> UInt32 {
  let t = date.timeIntervalSince1970 + 2_082_844_800 + Double(TimeZone.current.secondsFromGMT(for: date))
  return UInt32(clamping: Int64(t))
}

public final class ITunesDB {
  let root: Atom

  public init(data: Data) throws {
    root = try AtomParser.parse([UInt8](data))
    guard trackList != nil else { throw ITunesDBError("iTunesDB has no track list") }
    guard masterPlaylist != nil else { throw ITunesDBError("iTunesDB has no master playlist") }
  }

  /// An empty database, like libgpod's itdb_init_ipod: master playlist
  /// named after the iPod.
  public init(name: String) {
    var w = ByteWriter()
    w.tag("mhbd"); w.u32(244); w.u32(0); w.u32(1)
    w.u32(0x30)        // version (iTunes 9.2), what libgpod writes for every model
    w.u32(0)           // children, set below
    w.u64(Self.randomID())
    w.u16(1)           // platform: Mac
    w.u16(0)
    w.u64(Self.randomID()) // id_0x24
    w.u32(0)
    w.u16(0)           // hashing scheme
    w.zeros16(10)
    w.bytes += Array("en".utf8)
    w.u64(Self.randomID()) // library persistent id
    w.u32(0); w.u32(0)
    w.zeros32(5)       // hash58
    w.i32(TimeZone.current.secondsFromGMT())
    w.u16(0); w.u16(0); w.zeros32(11) // hash72
    w.zeros16(5); w.u8(0); w.u8(0); w.zeros32(14); w.zeros32(4)
    root = Atom(tag: "mhbd", header: w.bytes)
    // Same order as libgpod: tracks, podcast playlists, playlists, albums, artists.
    for (type, list) in [(1, "mhlt"), (3, "mhlp"), (2, "mhlp"), (4, "mhla"), (8, "mhli")] {
      root.children.append(Self.mhsd(UInt32(type), Self.list(list)))
    }
    Bytes.put32(&root.header, 20, UInt32(root.children.count))
    let mpl = Self.playlist(name: name, id: Self.randomID(), master: true, mhips: [])
    for list in playlistLists { list.children = [mpl] }
  }

  public func data() -> Data { Data(root.bytes) }

  // MARK: Structure

  func section(_ type: UInt32) -> Atom? { root.children.first { $0.tag == "mhsd" && $0.type == type } }
  var trackList: Atom? { section(1)?.children.first { $0.tag == "mhlt" } }
  /// Type 2 (normal) and type 3 (podcasts grouped) playlist lists.
  var playlistLists: [Atom] { [2, 3].compactMap { section($0)?.children.first { $0.tag == "mhlp" } } }
  var albumList: Atom? { section(4)?.children.first { $0.tag == "mhla" } }
  var artistList: Atom? { section(8)?.children.first { $0.tag == "mhli" } }
  var masterPlaylist: Atom? { section(2)?.children.first?.children.first(where: \.isMaster) }

  public var trackCount: Int { trackList?.children.count ?? 0 }
  public var name: String? { masterPlaylist?.string(MHOD.title) }
  public var hashingScheme: UInt16 { root.u16(0x30) }
  /// Any hash72/hashAB bytes: written by a model whose checksum we can't make.
  public var hasNewerChecksum: Bool {
    root.header.count >= 0xAB + 57 && (root.header[0x72..<0xA0].contains { $0 != 0 } || root.header[0xAB..<(0xAB + 57)].contains { $0 != 0 })
  }

  public var playlistNames: [String] {
    section(2)?.children.first?.children.filter { !$0.isMaster }.compactMap { $0.string(MHOD.title) } ?? []
  }

  func track(dbid: UInt64) -> Atom? { trackList?.children.first { $0.dbid == dbid } }
  public var dbids: [UInt64] { trackList?.children.map(\.dbid) ?? [] }
  public func playlistID(named name: String) -> UInt64? {
    section(2)?.children.first?.children.first { $0.string(MHOD.title) == name }?.playlistID
  }
  public func trackTitle(dbid: UInt64) -> String? { track(dbid: dbid)?.string(MHOD.title) }
  public func trackPath(dbid: UInt64) -> String? { track(dbid: dbid)?.string(MHOD.path) }
  public func trackString(dbid: UInt64, _ type: UInt32) -> String? { track(dbid: dbid)?.string(type) }
  public func playlistTrackIDs(named name: String) -> [UInt32] {
    guard let pl = section(2)?.children.first?.children.first(where: { $0.string(MHOD.title) == name }) else { return [] }
    return pl.children.filter { $0.tag == "mhip" }.map(\.itemTrackID)
  }
  public func trackID(dbid: UInt64) -> UInt32? { track(dbid: dbid)?.trackID }

  // MARK: Artwork links

  /// mhit fields that point at the ArtworkDB: artwork count (0x7C), size of
  /// the original image (0x80), has-artwork flag (0xA4: 1 yes, 2 no) and
  /// the mhii id (0x160).
  func setArtwork(dbid: UInt64, imageID: UInt32?, originalSize: Int) {
    guard let t = track(dbid: dbid) else { return }
    t.set16(0x7C, imageID == nil ? 0 : 1)
    t.set32(0x80, imageID == nil ? 0 : UInt32(clamping: originalSize))
    t.set8(0xA4, imageID == nil ? 2 : 1)
    t.set32(0x160, imageID ?? 0)
  }

  /// Tracks in database order: dbid and artwork link.
  var artworkLinks: [(dbid: UInt64, link: UInt32)] {
    (trackList?.children ?? []).map { ($0.dbid, $0.u32(0x160)) }
  }

  /// After the ArtworkDB's image ids were renumbered.
  func remapArtworkLinks(_ map: [UInt32: UInt32]) {
    for t in trackList?.children ?? [] where t.header.count >= 0x164 {
      let link = t.u32(0x160)
      if link != 0, let new = map[link] { t.set32(0x160, new) }
    }
  }

  // MARK: Play Counts / On-The-Go

  /// Merges the iPod's "Play Counts" file (one entry per track, in database
  /// order) into the tracks, as libgpod does when it reads the database.
  public func applyPlayCounts(_ data: Data) throws {
    let d = [UInt8](data)
    guard d.count >= 16, AtomParser.tag(d, 0) == "mhdp" else { throw ITunesDBError("not a Play Counts file") }
    let hlen = Int(Bytes.u32(d, 4)), elen = Int(Bytes.u32(d, 8)), count = Int(Bytes.u32(d, 12))
    guard hlen >= 0x60, elen >= 0x0C else { throw ITunesDBError("unexpected Play Counts layout") }
    let tracks = trackList?.children ?? []
    for i in 0..<min(count, tracks.count) {
      let o = hlen + i * elen
      guard o + elen <= d.count else { break }
      let t = tracks[i]
      let plays = Bytes.u32(d, o), played = Bytes.u32(d, o + 4), bookmark = Bytes.u32(d, o + 8)
      t.set32(0x50, t.u32(0x50) &+ plays)
      if played != 0 { t.set32(0x58, played) }
      if bookmark != 0 { t.set32(0x6C, bookmark) }
      if elen >= 0x10 { t.set8(0x1F, UInt8(clamping: Bytes.u32(d, o + 12))) }
      if elen >= 0x1C {
        t.set32(0x9C, t.u32(0x9C) &+ Bytes.u32(d, o + 20))
        let skipped = Bytes.u32(d, o + 24)
        if skipped != 0 { t.set32(0xA0, skipped) }
      }
    }
  }

  /// An On-The-Go playlist file: track positions in database order.
  public func onTheGoTracks(_ data: Data) throws -> [UInt64] {
    let d = [UInt8](data)
    guard d.count >= 16, AtomParser.tag(d, 0) == "mhpo" else { throw ITunesDBError("not an On-The-Go playlist file") }
    let hlen = Int(Bytes.u32(d, 4)), elen = Int(Bytes.u32(d, 8)), count = Int(Bytes.u32(d, 12))
    guard hlen >= 0x14, elen >= 4 else { throw ITunesDBError("unexpected On-The-Go playlist layout") }
    let tracks = trackList?.children ?? []
    return (0..<count).compactMap { i in
      let o = hlen + i * elen
      guard o + 4 <= d.count else { return nil }
      let n = Int(Bytes.u32(d, o))
      return n < tracks.count ? tracks[n].dbid : nil
    }
  }

  // MARK: Editing

  /// Replaces the tracks in `remove` and the playlists in `removePlaylists`
  /// with `tracks` and `playlists`. A track whose dbid is both removed and
  /// re-added keeps its play count, rating and bookmark. Everything else is
  /// left as it was. The master playlist and its sort indexes, and the
  /// album and artist lists, are brought up to date.
  public func replace(tracks newTracks: [ITunesTrack], removing remove: Set<UInt64>,
                      playlists newPlaylists: [ITunesPlaylist], removingPlaylists removePlaylists: Set<UInt64>) {
    guard let list = trackList else { return }
    let id0x24 = root.u64(0x24)
    let now = macTime()

    // Old headers of the tracks being rewritten, for their play counts.
    var previous: [UInt64: Atom] = [:]
    for t in list.children where remove.contains(t.dbid) { previous[t.dbid] = t }
    // A rewritten track keeps its id, so playlists pointing at it still do.
    let readded = Set(newTracks.map(\.dbid))
    let removedIDs = Set(previous.values.filter { !readded.contains($0.dbid) }.map(\.trackID))
    list.children.removeAll { remove.contains($0.dbid) }
    var reusable = Dictionary(previous.values.map { ($0.dbid, $0.trackID) }, uniquingKeysWith: { a, _ in a })

    // Track ids: keep the existing ones (playlists point at them), number
    // new tracks after the highest.
    var nextID = max((list.children + Array(previous.values)).map(\.trackID).max() ?? 0, 51) + 1 // libgpod starts at 52
    let albums = AlbumIndex(albumList), artists = ArtistIndex(artistList)

    let taken = Set(list.children.map(\.trackID))
    var added: [Atom] = []
    for t in newTracks {
      var id = reusable.removeValue(forKey: t.dbid) ?? nextID
      if taken.contains(id) || added.contains(where: { $0.trackID == id }) { id = nextID }
      if id == nextID { nextID += 1 }
      let atom = Self.track(t, id: id, albumID: albums.id(album: t.album, artist: t.artist),
                            artistID: artists.id(artist: t.artist), id0x24: id0x24, added: now,
                            previous: previous[t.dbid])
      added.append(atom)
    }
    list.children += added
    albums.prune(keeping: list.children)
    artists.prune(keeping: list.children)

    let byDBID = Dictionary(list.children.map { ($0.dbid, $0.trackID) }, uniquingKeysWith: { a, _ in a })
    for pls in playlistLists {
      // Drop the replaced playlists, and replaced tracks from the others.
      pls.children.removeAll { !$0.isMaster && removePlaylists.contains($0.playlistID) }
      for pl in pls.children where !pl.isMaster { Self.removeItems(of: removedIDs, from: pl) }
      for p in newPlaylists {
        let mhips = p.trackDBIDs.compactMap { byDBID[$0] }.enumerated().map { Self.item(trackID: $1, position: $0, time: now) }
        pls.children.append(Self.playlist(name: p.name, id: p.id, master: false, mhips: mhips))
      }
      if let mpl = pls.children.first(where: \.isMaster) { rebuildMaster(mpl, removed: removedIDs, added: added, time: now) }
    }
  }

  /// Every track belongs to the master playlist, which also carries the
  /// sorted indexes the iPod uses for its Songs/Artists/Albums menus
  /// (mhod 52, jump tables in mhod 53).
  private func rebuildMaster(_ mpl: Atom, removed: Set<UInt32>, added: [Atom], time: UInt32) {
    var ids = mpl.children.filter { $0.tag == "mhip" }.map(\.itemTrackID).filter { !removed.contains($0) }
    let existing = Set(trackList?.children.map(\.trackID) ?? [])
    ids = ids.filter { existing.contains($0) }
    ids += added.map(\.trackID).filter { !ids.contains($0) }

    let tracksByID = Dictionary((trackList?.children ?? []).map { ($0.trackID, $0) }, uniquingKeysWith: { a, _ in a })
    let members = ids.compactMap { tracksByID[$0] }
    let kept = mpl.children.filter { $0.tag == "mhod" && $0.type != MHOD.libraryIndex && $0.type != MHOD.jumpTable && !Self.isPositionMHOD($0) }
    var indexes: [Atom] = []
    if !members.isEmpty {
      let keys = members.enumerated().map { SortKeys(track: $1, index: $0) }
      for kind in SortKeys.Kind.allCases {
        indexes += Self.libraryIndex(kind, keys)
      }
    }
    let mhips = members.enumerated().map { Self.item(trackID: $1.trackID, position: $0, time: time) }
    mpl.children = kept + indexes + mhips
    mpl.set32(12, UInt32(kept.count + indexes.count))
    mpl.set32(16, UInt32(mhips.count))
  }

  /// Removes the playlist items pointing at removed tracks. Old databases
  /// put the position mhod after the mhip rather than inside it.
  private static func removeItems(of removed: Set<UInt32>, from pl: Atom) {
    guard !removed.isEmpty else { return }
    var out: [Atom] = []
    var dropNextPosition = false
    for c in pl.children {
      if c.tag == "mhip" {
        dropNextPosition = removed.contains(c.itemTrackID)
        if !dropNextPosition { out.append(c) }
        dropNextPosition = dropNextPosition && c.children.isEmpty
        continue
      }
      if dropNextPosition && isPositionMHOD(c) {
        dropNextPosition = false
        continue
      }
      dropNextPosition = false
      out.append(c)
    }
    if out.count != pl.children.count {
      pl.children = out
      pl.set32(16, UInt32(out.filter { $0.tag == "mhip" }.count))
    }
  }

  private static func isPositionMHOD(_ a: Atom) -> Bool {
    a.tag == "mhod" && a.type == MHOD.playlist && Bytes.u32(a.header, 8) == 44
  }

  // MARK: Builders (libgpod's mk_* functions)

  static func randomID() -> UInt64 {
    var id: UInt64 = 0
    while id == 0 { id = UInt64.random(in: 1...UInt64.max) }
    return id
  }

  static func mhsd(_ type: UInt32, _ list: Atom) -> Atom {
    var w = ByteWriter()
    w.tag("mhsd"); w.u32(96); w.u32(0); w.u32(type); w.zeros32(20)
    return Atom(tag: "mhsd", header: w.bytes, children: [list])
  }

  static func list(_ tag: String) -> Atom {
    var w = ByteWriter()
    w.tag(tag); w.u32(92); w.u32(0); w.zeros32(20)
    return Atom(tag: tag, header: w.bytes)
  }

  /// mk_mhit, for an MP3 (0x248-byte header as written for every model).
  static func track(_ t: ITunesTrack, id: UInt32, albumID: UInt32, artistID: UInt32, id0x24: UInt64,
                    added: UInt32, previous: Atom?) -> Atom {
    var w = ByteWriter()
    w.tag("mhit"); w.u32(0x248); w.u32(0); w.u32(0)
    w.u32(id)
    w.u32(1)                                    // visible
    w.u32(0x4D50_3320)                          // filetype marker "MP3 "
    w.u8(0); w.u8(1)                            // type1, type2 (MP3)
    w.u8(0)                                     // compilation
    w.u8(previous?.u8(0x1F) ?? 0)               // rating
    w.u32(added)                                // modified
    w.u32(UInt32(clamping: t.size))
    w.u32(UInt32(clamping: t.durationMS))
    w.u32(UInt32(clamping: t.trackNumber))
    w.u32(UInt32(clamping: t.trackCount))
    w.u32(0)                                    // year
    w.u32(UInt32(clamping: t.bitrate))
    w.u32(UInt32(clamping: t.sampleRate) << 16)
    w.u32(0); w.u32(0); w.u32(0); w.u32(0)      // volume, start, stop, soundcheck
    w.u32(previous?.u32(0x50) ?? 0)             // play count
    w.u32(previous?.u32(0x54) ?? 0)             // play count 2
    w.u32(previous?.u32(0x58) ?? 0)             // last played
    w.u32(1); w.u32(1)                          // disc 1 of 1
    w.u32(0)                                    // drm user id
    w.u32(previous?.u32(0x68) ?? added)         // added
    w.u32(previous?.u32(0x6C) ?? 0)             // bookmark
    w.u64(t.dbid)
    w.u8(0)                                     // checked
    w.u8(0)                                     // app rating
    w.u16(0)                                    // BPM
    w.u16(0)                                    // artwork count
    w.u16(0xFFFF)                               // unk126: 0xffff for MP3
    w.u32(0)                                    // artwork size
    w.u32(0)
    w.f32(Float(t.sampleRate))
    w.u32(0)                                    // released
    w.u16(0x000C)                               // unk144: MP3
    w.u16(0)                                    // explicit
    w.u32(0); w.u32(0)
    w.u32(previous?.u32(0x9C) ?? 0)             // skip count
    w.u32(previous?.u32(0xA0) ?? 0)             // last skipped
    w.u8(2)                                     // has artwork: no
    w.u8(0)                                     // skip when shuffling
    w.u8(1)                                     // remember playback position (stories)
    w.u8(0)
    w.u64(t.dbid)                               // dbid2
    w.u8(0); w.u8(0)                            // lyrics, movie
    w.u8(1)                                     // mark unplayed: no bullet
    w.u8(0)
    w.u32(0); w.u32(0)                          // unk180, pregap
    w.u64(UInt64(Double(t.durationMS) / 1000 * Double(t.sampleRate))) // sample count
    w.u32(0); w.u32(0); w.u32(0)                // unk196, postgap, unk204
    w.u32(1)                                    // media type: audio
    w.u32(0); w.u32(0)                          // season, episode
    w.zeros32(9)                                // 0xDC..0xFF
    w.u16(0); w.u16(0)                          // gapless flags
    w.zeros32(7)
    w.u32(albumID)                              // 0x120
    w.u64(id0x24)
    w.u32(UInt32(clamping: t.size))
    w.u32(0); w.u64(0x808080808080); w.u32(0)
    w.zeros32(2); w.u32(0); w.zeros32(5)
    w.u32(0)                                    // 0x160 mhii link (artwork)
    w.u32(0); w.u32(1); w.u32(0)
    w.zeros32(28)
    w.u32(artistID)                             // 0x1E0
    w.zeros32(4)
    w.u32(0)                                    // 0x1F4 composer id
    w.zeros32(20)
    assert(w.bytes.count == 0x248)

    var mhods = [MHOD.string(MHOD.title, t.title)]
    if !t.artist.isEmpty { mhods.append(MHOD.string(MHOD.artist, t.artist)) }
    if !t.album.isEmpty { mhods.append(MHOD.string(MHOD.album, t.album)) }
    mhods.append(MHOD.string(MHOD.filetype, "MPEG audio file"))
    mhods.append(MHOD.string(MHOD.path, t.ipodPath))
    if !t.genre.isEmpty { mhods.append(MHOD.string(MHOD.genre, t.genre)) }
    let atom = Atom(tag: "mhit", header: w.bytes, children: mhods)
    atom.set32(12, UInt32(mhods.count))
    return atom
  }

  /// mk_mhyp + title + preferences mhods.
  static func playlist(name: String, id: UInt64, master: Bool, mhips: [Atom]) -> Atom {
    var w = ByteWriter()
    w.tag("mhyp"); w.u32(108); w.u32(0)
    w.u32(2)                         // mhods
    w.u32(UInt32(mhips.count))
    w.u8(master ? 1 : 0); w.u8(0); w.u8(0); w.u8(0)
    w.u32(macTime())
    w.u64(id)
    w.u32(0)
    w.u16(1)                         // string mhod count
    w.u16(0)                         // podcast flag
    w.u32(1)                         // sort order: manual
    w.zeros32(15)
    return Atom(tag: "mhyp", header: w.bytes,
                children: [MHOD.string(MHOD.title, name), MHOD.playlistPrefs()] + mhips)
  }

  /// mk_mhip with its position mhod inside (iTunes 4.9+ layout).
  static func item(trackID: UInt32, position: Int, time: UInt32) -> Atom {
    var w = ByteWriter()
    w.tag("mhip"); w.u32(76); w.u32(0)
    w.u32(1)          // children
    w.u32(0); w.u32(0) // podcast group flag, group id
    w.u32(trackID)
    w.u32(time)
    w.u32(0)          // podcast group ref
    w.zeros32(10)
    return Atom(tag: "mhip", header: w.bytes, children: [MHOD.position(position)])
  }

  // MARK: Library indexes (mhod 52/53)

  struct SortKeys {
    enum Kind: UInt32, CaseIterable { case title = 0x03, artist = 0x05, album = 0x04, genre = 0x07, composer = 0x12 }
    let index: Int
    let title: String, album: String, artist: String, genre: String, composer: String
    let trackNumber: UInt32, disc: UInt32

    init(track t: Atom, index: Int) {
      self.index = index
      title = t.string(MHOD.sortTitle).nonEmpty ?? t.string(MHOD.title) ?? ""
      album = t.string(MHOD.sortAlbum).nonEmpty ?? t.string(MHOD.album) ?? ""
      artist = t.string(MHOD.sortArtist).nonEmpty ?? Self.sortArtist(t.string(MHOD.artist) ?? "")
      genre = t.string(MHOD.genre) ?? ""
      composer = t.string(MHOD.sortComposer).nonEmpty ?? t.string(MHOD.composer) ?? ""
      trackNumber = t.trackNumber
      disc = t.discNumber
    }

    /// "The Beatles" sorts as "Beatles, The", like iTunes.
    static func sortArtist(_ a: String) -> String {
      a.lowercased().hasPrefix("the ") ? String(a.dropFirst(4)) + ", The" : a
    }

    func key(_ kind: Kind) -> String {
      switch kind {
      case .title: title
      case .album: album
      case .artist: artist
      case .genre: genre
      case .composer: composer
      }
    }

    /// libgpod's sort order for each index.
    static func ordered(_ kind: Kind, _ a: SortKeys, _ b: SortKeys) -> Bool {
      func cmp(_ x: String, _ y: String) -> ComparisonResult {
        x.compare(y, options: [.caseInsensitive], range: nil, locale: Locale.current)
      }
      var fields: [(SortKeys) -> String] = []
      switch kind {
      case .title: return cmp(a.title, b.title) == .orderedAscending
      case .album: fields = [\.album]
      case .artist: fields = [\.artist, \.album]
      case .genre: fields = [\.genre, \.artist, \.album]
      case .composer: fields = [\.composer, \.album]
      }
      for f in fields {
        let r = cmp(f(a), f(b))
        if r != .orderedSame { return r == .orderedAscending }
      }
      if a.disc != b.disc { return a.disc < b.disc }
      if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
      return cmp(a.title, b.title) == .orderedAscending
    }

    /// First letter or digit, upper-cased; "0" for digits and no letter.
    static func jumpLetter(_ s: String) -> UInt16 {
      guard let c = s.unicodeScalars.first(where: { CharacterSet.alphanumerics.contains($0) }) else { return 0x30 }
      guard CharacterSet.letters.contains(c) else { return 0x30 }
      return String(c).uppercased().utf16.first ?? 0x30
    }
  }

  static func libraryIndex(_ kind: SortKeys.Kind, _ keys: [SortKeys]) -> [Atom] {
    let sorted = keys.enumerated().sorted { l, r in
      SortKeys.ordered(kind, l.element, r.element) || (!SortKeys.ordered(kind, r.element, l.element) && l.offset < r.offset)
    }.map(\.element)

    var w = ByteWriter()
    w.tag("mhod"); w.u32(24); w.u32(UInt32(4 * sorted.count + 72)); w.u32(MHOD.libraryIndex); w.zeros32(2)
    var p = ByteWriter()
    p.u32(kind.rawValue); p.u32(UInt32(sorted.count)); p.zeros32(10)
    var jumps: [(letter: UInt16, start: UInt32, count: UInt32)] = []
    for (i, k) in sorted.enumerated() {
      p.u32(UInt32(k.index))
      let letter = SortKeys.jumpLetter(k.key(kind))
      if jumps.last?.letter == letter { jumps[jumps.count - 1].count += 1 } else { jumps.append((letter, UInt32(i), 1)) }
    }
    let index = Atom(tag: "mhod", header: w.bytes, payload: p.bytes)

    var jw = ByteWriter()
    jw.tag("mhod"); jw.u32(24); jw.u32(UInt32(12 * jumps.count + 40)); jw.u32(MHOD.jumpTable); jw.zeros32(2)
    var jp = ByteWriter()
    jp.u32(kind.rawValue); jp.u32(UInt32(jumps.count)); jp.zeros32(2)
    for j in jumps { jp.u16(j.letter); jp.u16(0); jp.u32(j.start); jp.u32(j.count) }
    return [index, Atom(tag: "mhod", header: jw.bytes, payload: jp.bytes)]
  }

  // MARK: Checksum (itdb_hash58.c)

  /// The iPod classic and the nano 3G/4G refuse a database without this
  /// HMAC-SHA1, keyed from the iPod's FireWire GUID.
  public static func writeHash58(_ db: inout Data, firewireID: [UInt8]) throws {
    guard db.count >= 0x6C else { throw ITunesDBError("iTunesDB too small for a checksum") }
    var bytes = [UInt8](db)
    let dbID = Array(bytes[0x18..<0x20]), unk32 = Array(bytes[0x32..<0x46])
    for i in 0x18..<0x20 { bytes[i] = 0 }
    for i in 0x32..<0x46 { bytes[i] = 0 }
    for i in 0x58..<0x6C { bytes[i] = 0 }
    Bytes.put16(&bytes, 0x30, 1) // hashing scheme: hash58
    let hash = hash58(firewireID: firewireID, data: bytes)
    bytes.replaceSubrange(0x58..<0x6C, with: hash)
    bytes.replaceSubrange(0x18..<0x20, with: dbID)
    bytes.replaceSubrange(0x32..<0x46, with: unk32)
    db = Data(bytes)
  }

  static func hash58(firewireID fw: [UInt8], data: [UInt8]) -> [UInt8] {
    func gcd(_ a: Int, _ b: Int) -> Int {
      var a = a, b = b
      while true {
        a %= b; if a == 0 { return b }
        b %= a; if b == 0 { return a }
      }
    }
    func lcm(_ a: Int, _ b: Int) -> Int { a == 0 || b == 0 ? 1 : (a * b) / gcd(a, b) }

    let id = fw + [UInt8](repeating: 0, count: max(0, 8 - fw.count))
    var y = [UInt8](repeating: 0, count: 16)
    for i in 0..<4 {
      let l = lcm(Int(id[2 * i]), Int(id[2 * i + 1]))
      let hi = (l & 0xFF00) >> 8, lo = l & 0xFF
      y[4 * i] = Hash58Tables.t1[hi]; y[4 * i + 1] = Hash58Tables.t2[hi]
      y[4 * i + 2] = Hash58Tables.t1[lo]; y[4 * i + 3] = Hash58Tables.t2[lo]
    }
    var key = [UInt8](Insecure.SHA1.hash(data: Hash58Tables.fixed + y)) // 20 bytes
    key += [UInt8](repeating: 0, count: 64 - key.count)
    var inner = Insecure.SHA1()
    inner.update(data: key.map { $0 ^ 0x36 })
    inner.update(data: data)
    let innerHash = [UInt8](inner.finalize())
    var outer = Insecure.SHA1()
    outer.update(data: key.map { $0 ^ 0x5C })
    outer.update(data: innerHash)
    return [UInt8](outer.finalize())
  }
}

private extension Optional where Wrapped == String {
  var nonEmpty: String? { self.flatMap { $0.isEmpty ? nil : $0 } }
}

// MARK: - Album and artist lists

/// mhla (albums, mhsd 4): one mhia per album/artist pair, referenced by
/// each track's album id. Existing entries are reused and kept as is.
final class AlbumIndex {
  private let list: Atom?
  private var next: UInt32
  private var byKey: [String: UInt32] = [:]

  init(_ list: Atom?) {
    self.list = list
    next = (list?.children.map(\.itemID).max() ?? 0) + 1
    for a in list?.children ?? [] {
      byKey[Self.key(a.string(MHOD.albumAlbum) ?? "", a.string(MHOD.albumArtistName) ?? "")] = a.itemID
    }
  }

  static func key(_ album: String, _ artist: String) -> String { album + "\u{0}" + artist }

  func id(album: String, artist: String) -> UInt32 {
    guard let list else { return 0 }
    if let id = byKey[Self.key(album, artist)] { return id }
    let id = next
    next += 1
    byKey[Self.key(album, artist)] = id
    var w = ByteWriter()
    w.tag("mhia"); w.u32(88); w.u32(0); w.u32(0); w.u32(id); w.u64(ITunesDB.randomID()); w.u32(2); w.zeros32(14)
    var mhods: [Atom] = []
    if !album.isEmpty { mhods.append(MHOD.string(MHOD.albumAlbum, album)) }
    if !artist.isEmpty { mhods.append(MHOD.string(MHOD.albumArtistName, artist)) }
    let atom = Atom(tag: "mhia", header: w.bytes, children: mhods)
    atom.set32(12, UInt32(mhods.count))
    list.children.append(atom)
    return id
  }

  /// Drops albums no track points to any more (only Merlin's can go away).
  func prune(keeping tracks: [Atom]) {
    guard let list, tracks.allSatisfy({ $0.header.count >= 0x124 }) else { return }
    let used = Set(tracks.map(\.albumID))
    list.children.removeAll { !used.contains($0.itemID) }
  }
}

/// mhli (artists, mhsd 8): one mhii per artist, referenced at mhit+0x1E0.
final class ArtistIndex {
  private let list: Atom?
  private var next: UInt32
  private var byName: [String: UInt32] = [:]

  init(_ list: Atom?) {
    self.list = list
    next = (list?.children.map(\.itemID).max() ?? 0) + 1
    for a in list?.children ?? [] { byName[a.string(MHOD.artistName) ?? ""] = a.itemID }
  }

  func id(artist: String) -> UInt32 {
    guard let list, !artist.isEmpty else { return 0 }
    if let id = byName[artist] { return id }
    let id = next
    next += 1
    byName[artist] = id
    var w = ByteWriter()
    w.tag("mhii"); w.u32(80); w.u32(0); w.u32(1); w.u32(id); w.u64(ITunesDB.randomID()); w.u32(2); w.zeros32(12)
    list.children.append(Atom(tag: "mhii", header: w.bytes, children: [MHOD.string(MHOD.artistName, artist)]))
    return id
  }

  func prune(keeping tracks: [Atom]) {
    guard let list, tracks.allSatisfy({ $0.header.count >= 0x1E4 }) else { return }
    let used = Set(tracks.map(\.artistID))
    list.children.removeAll { !used.contains($0.itemID) }
  }
}

enum Hash58Tables {
  static let t1: [UInt8] = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
  ]
  static let t2: [UInt8] = [
    0x52, 0x09, 0x6A, 0xD5, 0x30, 0x36, 0xA5, 0x38, 0xBF, 0x40, 0xA3, 0x9E, 0x81, 0xF3, 0xD7, 0xFB,
    0x7C, 0xE3, 0x39, 0x82, 0x9B, 0x2F, 0xFF, 0x87, 0x34, 0x8E, 0x43, 0x44, 0xC4, 0xDE, 0xE9, 0xCB,
    0x54, 0x7B, 0x94, 0x32, 0xA6, 0xC2, 0x23, 0x3D, 0xEE, 0x4C, 0x95, 0x0B, 0x42, 0xFA, 0xC3, 0x4E,
    0x08, 0x2E, 0xA1, 0x66, 0x28, 0xD9, 0x24, 0xB2, 0x76, 0x5B, 0xA2, 0x49, 0x6D, 0x8B, 0xD1, 0x25,
    0x72, 0xF8, 0xF6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xD4, 0xA4, 0x5C, 0xCC, 0x5D, 0x65, 0xB6, 0x92,
    0x6C, 0x70, 0x48, 0x50, 0xFD, 0xED, 0xB9, 0xDA, 0x5E, 0x15, 0x46, 0x57, 0xA7, 0x8D, 0x9D, 0x84,
    0x90, 0xD8, 0xAB, 0x00, 0x8C, 0xBC, 0xD3, 0x0A, 0xF7, 0xE4, 0x58, 0x05, 0xB8, 0xB3, 0x45, 0x06,
    0xD0, 0x2C, 0x1E, 0x8F, 0xCA, 0x3F, 0x0F, 0x02, 0xC1, 0xAF, 0xBD, 0x03, 0x01, 0x13, 0x8A, 0x6B,
    0x3A, 0x91, 0x11, 0x41, 0x4F, 0x67, 0xDC, 0xEA, 0x97, 0xF2, 0xCF, 0xCE, 0xF0, 0xB4, 0xE6, 0x73,
    0x96, 0xAC, 0x74, 0x22, 0xE7, 0xAD, 0x35, 0x85, 0xE2, 0xF9, 0x37, 0xE8, 0x1C, 0x75, 0xDF, 0x6E,
    0x47, 0xF1, 0x1A, 0x71, 0x1D, 0x29, 0xC5, 0x89, 0x6F, 0xB7, 0x62, 0x0E, 0xAA, 0x18, 0xBE, 0x1B,
    0xFC, 0x56, 0x3E, 0x4B, 0xC6, 0xD2, 0x79, 0x20, 0x9A, 0xDB, 0xC0, 0xFE, 0x78, 0xCD, 0x5A, 0xF4,
    0x1F, 0xDD, 0xA8, 0x33, 0x88, 0x07, 0xC7, 0x31, 0xB1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xEC, 0x5F,
    0x60, 0x51, 0x7F, 0xA9, 0x19, 0xB5, 0x4A, 0x0D, 0x2D, 0xE5, 0x7A, 0x9F, 0x93, 0xC9, 0x9C, 0xEF,
    0xA0, 0xE0, 0x3B, 0x4D, 0xAE, 0x2A, 0xF5, 0xB0, 0xC8, 0xEB, 0xBB, 0x3C, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2B, 0x04, 0x7E, 0xBA, 0x77, 0xD6, 0x26, 0xE1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0C, 0x7D,
  ]
  static let fixed: [UInt8] = [
    0x67, 0x23, 0xFE, 0x30, 0x45, 0x33, 0xF8, 0x90, 0x99, 0x21, 0x07, 0xC1, 0xD0, 0x12, 0xB2, 0xA1, 0x07, 0x81,
  ]
}
