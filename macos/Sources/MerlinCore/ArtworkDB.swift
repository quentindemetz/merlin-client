import CoreGraphics
import Foundation
import ImageIO

// Cover art on the iPod, ported from libgpod (db-artwork-writer.c,
// ithumb-writer.c, the artwork tables of itdb_device.c).
//
// iPod_Control/Artwork/ArtworkDB lists images; each image (mhii) belongs to
// a track (its dbid) and has one thumbnail per size the iPod shows (mhod 2 >
// mhni > mhod 3 with the file name). The pixels themselves are in
// F<format>_<n>.ithmb files, as raw RGB565. Each track's mhit points back at
// its mhii.
//
//   mhfd
//     mhsd 1 > mhli > mhii > mhod 2 > mhni > mhod 3 ":F1028_1.ithmb"
//     mhsd 2 > mhla            (photo albums: empty here)
//     mhsd 3 > mhlf > mhif     (one per thumbnail format)
//
// As for the iTunesDB, the owner's images are kept as they are. Merlin's
// thumbnails go to their own .ithmb files, written fresh each time.

/// A cover size the iPod uses (all RGB565 little-endian on supported models).
public struct ArtworkFormat: Hashable, Sendable {
  public let id: Int
  public let width: Int
  public let height: Int
  /// Rows are padded to a multiple of this many bytes (0: none).
  public let rowAlignment: Int

  public init(id: Int, width: Int, height: Int, rowAlignment: Int = 0) {
    self.id = id
    self.width = width
    self.height = height
    self.rowAlignment = rowAlignment
  }

  var rowPixels: Int {
    let align = rowAlignment / 2
    guard align > 0, width % align != 0 else { return width }
    return width + align - width % align
  }

  var byteSize: Int { rowPixels * height * 2 }

  static let photo = [ArtworkFormat(id: 1017, width: 56, height: 56), ArtworkFormat(id: 1016, width: 140, height: 140)]
  static let nano = [ArtworkFormat(id: 1031, width: 42, height: 42), ArtworkFormat(id: 1027, width: 100, height: 100)]
  static let video = [ArtworkFormat(id: 1028, width: 100, height: 100), ArtworkFormat(id: 1029, width: 200, height: 200)]
  static let classic = [ArtworkFormat(id: 1061, width: 56, height: 56), ArtworkFormat(id: 1055, width: 128, height: 128),
                        ArtworkFormat(id: 1068, width: 128, height: 128), ArtworkFormat(id: 1060, width: 320, height: 320)]
  static let nano4 = [ArtworkFormat(id: 1055, width: 128, height: 128), ArtworkFormat(id: 1068, width: 128, height: 128),
                      ArtworkFormat(id: 1071, width: 240, height: 240), ArtworkFormat(id: 1074, width: 50, height: 50),
                      ArtworkFormat(id: 1078, width: 80, height: 80), ArtworkFormat(id: 1084, width: 240, height: 240)]

  /// SysInfoExtended's AlbumArt entries in RGB565 LE ("L565").
  static func fromSysInfoExtended(_ list: [[String: Any]]) -> [ArtworkFormat] {
    list.compactMap { d in
      guard (d["PixelFormat"] as? String)?.uppercased() == "4C353635",
            let id = d["FormatId"] as? Int, let w = d["RenderWidth"] as? Int, let h = d["RenderHeight"] as? Int else { return nil }
      let align = (d["RowBytesAlignment"] as? Int) ?? ((d["AlignRowBytes"] as? Bool) == true ? 4 : 0)
      return ArtworkFormat(id: id, width: w, height: h, rowAlignment: align)
    }
  }
}

extension IPodGeneration {
  var coverFormats: [ArtworkFormat] {
    switch self {
    case .photo: ArtworkFormat.photo
    case .video1, .video2: ArtworkFormat.video
    case .nano1, .nano2: ArtworkFormat.nano
    case .nano3, .classic1, .classic2, .classic3: ArtworkFormat.classic
    case .nano4: ArtworkFormat.nano4
    default: []
    }
  }

  /// Several tracks can share one image (itdb_device_supports_sparse_artwork).
  var sparseArtwork: Bool { [.nano3, .nano4, .classic1, .classic2, .classic3].contains(self) }
}

/// One thumbnail of one cover, ready to write.
struct Thumbnail {
  let format: ArtworkFormat
  let pixels: [UInt8]
  let width: Int, height: Int // excluding padding on the right/bottom
  let hpad: Int, vpad: Int
}

enum CoverRenderer {
  static func image(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
  }

  /// Scales to fit (no crop) and centres on black, like ithumb-writer.
  static func thumbnail(_ image: CGImage, _ f: ArtworkFormat) -> Thumbnail? {
    let iw = Double(image.width), ih = Double(image.height)
    guard iw > 0, ih > 0 else { return nil }
    let ws = Double(f.width) / iw, hs = Double(f.height) / ih
    var sw = f.width, sh = f.height
    if ws < hs { sh = min(Int((ih * ws).rounded(.up)), f.height) } else if ws > hs { sw = min(Int((iw * hs).rounded(.up)), f.width) }

    var rgba = [UInt8](repeating: 0, count: sw * sh * 4)
    let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
      return true
    }
    guard drawn else { return nil }

    let hpad = (f.width - sw) / 2, vpad = (f.height - sh) / 2
    let row = f.rowPixels
    var out = [UInt8](repeating: 0, count: f.byteSize) // black = 0x0000
    for y in 0..<sh {
      for x in 0..<sw {
        let p = (y * sw + x) * 4
        let v = UInt16(rgba[p] >> 3) << 11 | UInt16(rgba[p + 1] >> 2) << 5 | UInt16(rgba[p + 2] >> 3)
        let o = ((y + vpad) * row + x + hpad) * 2
        out[o] = UInt8(v & 0xFF)
        out[o + 1] = UInt8(v >> 8)
      }
    }
    return Thumbnail(format: f, pixels: out, width: sw, height: sh, hpad: hpad, vpad: vpad)
  }
}

final class ArtworkDB {
  let root: Atom

  init(data: Data) throws {
    root = try AtomParser.parse([UInt8](data), root: "mhfd")
    guard imageList != nil else { throw ITunesDBError("ArtworkDB has no image list") }
  }

  /// write_mhfd for an iPod without artwork yet.
  init(formats: [ArtworkFormat]) {
    var w = ByteWriter()
    w.tag("mhfd"); w.u32(0x84); w.u32(0); w.u32(0)
    w.u32(2)          // unknown2: 2 (iTunes 7 wipes the database if 1)
    w.u32(3)          // children
    w.u32(0)
    w.u32(0)          // next id
    w.u64(0); w.u64(0)
    w.u8(2); w.u8(0); w.u8(0); w.u8(0)
    w.bytes += [UInt8](repeating: 0, count: 0x84 - w.bytes.count)
    root = Atom(tag: "mhfd", header: w.bytes)
    for (index, list) in [(1, "mhli"), (2, "mhla"), (3, "mhlf")] {
      root.children.append(Self.mhsd(index, Self.list(list)))
    }
    for f in formats { fileList?.children.append(Self.mhif(f)) }
  }

  func data() -> Data { Data(root.bytes) }

  func section(_ index: UInt16) -> Atom? { root.children.first { $0.tag == "mhsd" && $0.u16(12) == index } }
  var imageList: Atom? { section(1)?.children.first { $0.tag == "mhli" } }
  var fileList: Atom? { section(3)?.children.first { $0.tag == "mhlf" } }

  var images: [Atom] { imageList?.children ?? [] }

  static func songID(_ mhii: Atom) -> UInt64 { mhii.u64(20) }
  static func imageID(_ mhii: Atom) -> UInt32 { mhii.u32(16) }

  /// The .ithmb files an image's thumbnails are in (":F1028_1.ithmb" -> "F1028_1.ithmb").
  static func files(_ mhii: Atom) -> [String] {
    mhii.children.compactMap { mhod in
      guard mhod.tag == "mhod", mhod.u16(12) == 2, mhod.payload.count >= 12 else { return nil }
      let p = mhod.payload
      let hlen = Int(Bytes.u32(p, 4))
      let o = hlen // the mhod 3 inside the mhni
      guard o + 36 <= p.count, AtomParser.tag(p, o) == "mhod" else { return nil }
      let len = Int(Bytes.u32(p, o + 24))
      guard o + 36 + len <= p.count else { return nil }
      let raw = Array(p[(o + 36)..<(o + 36 + len)])
      let name: String
      if p[o + 28] == 2 {
        name = String(decoding: stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }, as: UTF16.self)
      } else {
        name = String(decoding: raw, as: UTF8.self)
      }
      return name.split(separator: ":").last.map(String.init)
    }
  }

  func ensureFormats(_ formats: [ArtworkFormat]) {
    guard let list = fileList else { return }
    let have = Set(list.children.map { Int($0.u32(16)) })
    for f in formats where !have.contains(f.id) { list.children.append(Self.mhif(f)) }
  }

  /// Puts images in track order and numbers them from 0x64, like libgpod;
  /// returns old id -> new id so the tracks' links can follow.
  func renumber(trackOrder: [(dbid: UInt64, link: UInt32)]) -> [UInt32: UInt32] {
    guard let list = imageList else { return [:] }
    var rank: [UInt32: Int] = [:]
    var position: [UInt64: Int] = [:]
    for (i, t) in trackOrder.enumerated() {
      if t.link != 0, rank[t.link] == nil { rank[t.link] = i }
      if position[t.dbid] == nil { position[t.dbid] = i }
    }
    let keyed = list.children.enumerated().map { i, a -> (Int, Int, Atom) in
      (rank[Self.imageID(a)] ?? position[Self.songID(a)] ?? Int.max, i, a)
    }
    list.children = keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    var map: [UInt32: UInt32] = [:]
    var next: UInt32 = 0x64
    for a in list.children {
      map[Self.imageID(a)] = next
      a.set32(16, next)
      next += 1
    }
    root.set32(28, list.children.isEmpty ? 0 : next - 1) // next_id: highest id used
    return map
  }

  // MARK: Builders

  static func mhsd(_ index: Int, _ list: Atom) -> Atom {
    var w = ByteWriter()
    w.tag("mhsd"); w.u32(0x60); w.u32(0); w.u16(UInt16(index)); w.u16(0)
    w.bytes += [UInt8](repeating: 0, count: 0x60 - w.bytes.count)
    return Atom(tag: "mhsd", header: w.bytes, children: [list])
  }

  static func list(_ tag: String) -> Atom {
    var w = ByteWriter()
    w.tag(tag); w.u32(0x5C); w.u32(0)
    w.bytes += [UInt8](repeating: 0, count: 0x5C - w.bytes.count)
    return Atom(tag: tag, header: w.bytes)
  }

  static func mhif(_ f: ArtworkFormat) -> Atom {
    var w = ByteWriter()
    w.tag("mhif"); w.u32(0x7C); w.u32(0x7C); w.u32(0); w.u32(UInt32(f.id)); w.u32(UInt32(f.width * f.height * 2))
    w.bytes += [UInt8](repeating: 0, count: 0x7C - w.bytes.count)
    return Atom(tag: "mhif", header: w.bytes)
  }

  /// write_mhii: one image, one location mhod per thumbnail.
  static func mhii(imageID: UInt32, songID: UInt64, originalSize: Int,
                   thumbs: [(Thumbnail, file: String, offset: Int)]) -> Atom {
    var w = ByteWriter()
    w.tag("mhii"); w.u32(0x98); w.u32(0); w.u32(UInt32(thumbs.count))
    w.u32(imageID)
    w.u64(songID)
    w.u32(0); w.u32(0); w.u32(0) // unknown4, rating, unknown6
    w.u32(0); w.u32(0)           // dates
    w.u32(UInt32(clamping: originalSize))
    w.bytes += [UInt8](repeating: 0, count: 0x98 - w.bytes.count)
    let mhods = thumbs.map { location($0.0, file: $0.file, offset: $0.offset) }
    return Atom(tag: "mhii", header: w.bytes, children: mhods)
  }

  /// mhod type 2 holding an mhni (stored as payload: the mhod is opaque to
  /// the parser).
  static func location(_ t: Thumbnail, file: String, offset: Int) -> Atom {
    // mhod 3: the file name, UTF-16, padded to 4 bytes
    let name = Array(":\(file)".utf16)
    let strBytes = name.count * 2
    let pad = (4 - (36 + strBytes) % 4) % 4
    var s = ByteWriter()
    s.tag("mhod"); s.u32(24); s.u32(UInt32(36 + strBytes + pad))
    s.u16(3); s.u8(0); s.u8(UInt8(pad))
    s.u32(0); s.u32(0)
    s.u32(UInt32(strBytes))
    s.u8(2); s.u8(0); s.u16(0) // encoding: UTF-16LE
    s.u32(0)
    for u in name { s.u16(u) }
    s.bytes += [UInt8](repeating: 0, count: pad)

    var n = ByteWriter()
    n.tag("mhni"); n.u32(0x4C); n.u32(UInt32(0x4C + s.bytes.count)); n.u32(1)
    n.u32(UInt32(t.format.id))
    n.u32(UInt32(offset))
    n.u32(UInt32(t.pixels.count))
    n.u16(UInt16(t.vpad)); n.u16(UInt16(t.hpad))
    n.u16(UInt16(t.vpad + t.height)); n.u16(UInt16(t.hpad + t.width))
    n.bytes += [UInt8](repeating: 0, count: 0x4C - n.bytes.count)
    n.bytes += s.bytes

    var m = ByteWriter()
    m.tag("mhod"); m.u32(24); m.u32(UInt32(24 + n.bytes.count)); m.u16(2); m.u16(0); m.u32(0); m.u32(0)
    return Atom(tag: "mhod", header: m.bytes, payload: n.bytes)
  }
}
