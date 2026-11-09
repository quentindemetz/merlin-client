import CoreGraphics
import Foundation
import ImageIO
@testable import MerlinCore
import Testing
import UniformTypeIdentifiers

/// A solid-colour JPEG/PNG.
func solidImage(_ url: URL, width: Int, height: Int, rgb: (CGFloat, CGFloat, CGFloat), png: Bool = false) throws {
  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let dest = CGImageDestinationCreateWithURL(url as CFURL, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
  #expect(CGImageDestinationFinalize(dest))
}

@Suite struct ArtworkRenderTests {
  @Test func rgb565LittleEndianWithPadding() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("red.png")
    try solidImage(url, width: 200, height: 100, rgb: (1, 0, 0), png: true)
    let image = try #require(CoverRenderer.image(url))
    let t = try #require(CoverRenderer.thumbnail(image, ArtworkFormat(id: 1028, width: 100, height: 100)))
    #expect(t.pixels.count == 100 * 100 * 2)
    #expect(t.width == 100 && t.height == 50 && t.vpad == 25 && t.hpad == 0)
    func px(_ x: Int, _ y: Int) -> UInt16 { UInt16(t.pixels[(y * 100 + x) * 2]) | UInt16(t.pixels[(y * 100 + x) * 2 + 1]) << 8 }
    #expect(px(50, 50) == 0xF800) // red
    #expect(px(50, 10) == 0)      // black band above
    #expect(px(50, 90) == 0)      // and below
  }

  @Test func rowAlignmentPadsRows() {
    #expect(ArtworkFormat(id: 1, width: 50, height: 50, rowAlignment: 16).rowPixels == 56)
    #expect(ArtworkFormat(id: 1, width: 56, height: 56, rowAlignment: 16).byteSize == 56 * 56 * 2)
  }

  @Test func artworkDBRoundTrip() throws {
    let adb = ArtworkDB(formats: ArtworkFormat.video)
    let t = Thumbnail(format: ArtworkFormat.video[0], pixels: [UInt8](repeating: 0, count: 20000), width: 100, height: 100, hpad: 0, vpad: 0)
    adb.imageList?.children.append(ArtworkDB.mhii(imageID: 999, songID: 42, originalSize: 1234, thumbs: [(t, "F1028_1.ithmb", 0)]))
    let back = try ArtworkDB(data: adb.data())
    #expect(back.data() == adb.data())
    #expect(back.images.count == 1)
    #expect(ArtworkDB.songID(back.images[0]) == 42)
    #expect(ArtworkDB.files(back.images[0]) == ["F1028_1.ithmb"])
    #expect(back.fileList?.children.map { $0.u32(16) } == [1028, 1029])
    let map = back.renumber(trackOrder: [(42, 999)])
    #expect(map == [999: 0x64])
    #expect(back.root.u32(28) == 0x64)
  }
}

@Suite final class IPodArtworkTransferTests {
  let dir = tempDir()
  lazy var mount = dir.appendingPathComponent("IPOD")

  deinit { try? FileManager.default.removeItem(at: dir) }

  static let target = "ipod:test"
  var folderCovers: [String] = []

  /// Histoires: Contes (t1 with its own cover, t2) and Fables (t3), each
  /// folder with a cover.
  func library(t1Cover: Bool = true) throws -> MediaLibrary {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("Library"))
    func image(_ rgb: (CGFloat, CGFloat, CGFloat)) throws -> URL {
      let u = dir.appendingPathComponent("\(UUID().uuidString).jpg")
      try solidImage(u, width: 300, height: 300, rgb: rgb)
      return u
    }
    let f1 = try lib.addFolder("Contes", section: "Histoires", cover: image((0, 1, 0)))
    let f2 = try lib.addFolder("Fables", section: "Histoires", cover: image((1, 0, 0)))
    folderCovers = [f1.cover!, f2.cover!]
    for (i, (id, folder)) in [("t1", f1), ("t2", f1), ("t3", f2)].enumerated() {
      let src = lib.scratchURL("mp3")
      try silentMP3(frames: 40 + i).write(to: src)
      _ = try lib.insertTrack(id: id, folderID: folder.id, title: id, artist: nil, episode: nil, duration: nil, audio: src,
                              cover: id == "t1" && t1Cover ? image((0, 0, 1)) : nil, source: .file, sourceID: nil, sourceName: nil)
    }
    return lib
  }

  func libraryContent(t1Cover: Bool = true) throws -> IPodContent {
    try IPodContent.build(library: try library(t1Cover: t1Cover), target: Self.target)
  }

  func device(model: String) throws -> IPodDevice {
    let control = mount.appendingPathComponent("iPod_Control")
    try FileManager.default.createDirectory(at: control.appendingPathComponent("iTunes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: control.appendingPathComponent("Device"), withIntermediateDirectories: true)
    try "ModelNumStr: \(model)\nFirewireGuid: 0x000A27001B2C3D4E\n"
      .write(to: control.appendingPathComponent("Device/SysInfo"), atomically: true, encoding: .utf8)
    return try #require(IPodDevice(mountPoint: mount))
  }

  func artworkFiles() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: mount.appendingPathComponent("iPod_Control/Artwork").path)) ?? [])
      .filter { $0.hasSuffix(".ithmb") }.sorted()
  }

  @Test func coversOnAnIPodVideo() throws {
    let ipod = try device(model: "xA147") // video: 100x100 and 200x200, one image per track
    let content = try libraryContent()
    #expect(content.items.map { $0.cover?.lastPathComponent } == ["t1.jpg"] + folderCovers)

    // The owner's track already has a cover.
    let transfer = IPodTransfer(device: ipod, out: Captured())
    let owner = ITunesDB(name: "iPod")
    owner.replace(tracks: [track("Mine", dbid: 7)], removing: [], playlists: [], removingPlaylists: [])
    owner.setArtwork(dbid: 7, imageID: 0x64, originalSize: 10)
    try owner.data().write(to: ipod.databaseURL)
    let adb = ArtworkDB(formats: ArtworkFormat.video)
    let ownerThumb = Thumbnail(format: ArtworkFormat.video[0], pixels: [], width: 100, height: 100, hpad: 0, vpad: 0)
    adb.imageList?.children.append(ArtworkDB.mhii(imageID: 0x64, songID: 7, originalSize: 10, thumbs: [(ownerThumb, "F1028_1.ithmb", 0)]))
    try FileManager.default.createDirectory(at: ipod.artworkDir, withIntermediateDirectories: true)
    try adb.data().write(to: transfer.artworkDBURL)
    try Data(count: 20000).write(to: ipod.artworkDir.appendingPathComponent("F1028_1.ithmb"))

    let s = try transfer.run(content)
    #expect(s.covers == 3)
    #expect(artworkFiles() == ["F1028_1.ithmb", "F1028_2.ithmb", "F1029_1.ithmb"])
    #expect(IPodTransfer.size(ipod.artworkDir.appendingPathComponent("F1028_2.ithmb")) == 3 * 100 * 100 * 2)
    #expect(IPodTransfer.size(ipod.artworkDir.appendingPathComponent("F1029_1.ithmb")) == 3 * 200 * 200 * 2)

    let db = try ITunesDB(data: Data(contentsOf: ipod.databaseURL))
    let art = try ArtworkDB(data: Data(contentsOf: transfer.artworkDBURL))
    #expect(art.images.count == 4)
    #expect(art.images.map(ArtworkDB.imageID) == [0x64, 0x65, 0x66, 0x67]) // track order, from 0x64
    for image in art.images {
      let t = try #require(db.track(dbid: ArtworkDB.songID(image)))
      #expect(t.u32(0x160) == ArtworkDB.imageID(image))
    }
    let manifest = transfer.loadManifest()
    let one = try #require(db.track(dbid: manifest.tracks["t1"]!.dbid))
    #expect(one.u8(0xA4) == 1 && one.u16(0x7C) == 1 && one.u32(0x80) > 0)
    #expect(manifest.artworkFiles.sorted() == ["F1028_2.ithmb", "F1029_1.ithmb"])

    // t1's 100x100 thumbnail is blue (RGB565 0x001F).
    let t1 = try #require(art.images.first { ArtworkDB.songID($0) == manifest.tracks["t1"]!.dbid })
    let file = try Data(contentsOf: ipod.artworkDir.appendingPathComponent(ArtworkDB.files(t1)[0]))
    let mhni = t1.children[0].payload
    let offset = Int(Bytes.u32(mhni, 20))
    let mid = offset + (50 * 100 + 50) * 2
    let blue = UInt16(file[mid]) | UInt16(file[mid + 1]) << 8
    #expect(blue & 0xF800 == 0 && blue & 0x1F >= 0x1C)

    // Again: fresh files, old ones gone, the owner's untouched.
    let again = try transfer.run(content)
    #expect(again.covers == 3)
    #expect(artworkFiles() == ["F1028_1.ithmb", "F1028_3.ithmb", "F1029_2.ithmb"])
    #expect(try ArtworkDB(data: Data(contentsOf: transfer.artworkDBURL)).images.count == 4)

    // Removing Merlin's content removes its covers.
    try transfer.removeAll()
    #expect(artworkFiles() == ["F1028_1.ithmb"])
    let left = try ArtworkDB(data: Data(contentsOf: transfer.artworkDBURL))
    #expect(left.images.map(ArtworkDB.songID) == [7])
    #expect(try ITunesDB(data: Data(contentsOf: ipod.databaseURL)).track(dbid: 7)?.u32(0x160) == 0x64)
  }

  @Test func classicSharesOneImagePerAlbumCover() throws {
    let ipod = try device(model: "xB029") // classic: four sizes, sparse artwork
    // Both Contes tracks use the folder cover.
    let transfer = IPodTransfer(device: ipod, out: Captured())
    let s = try transfer.run(libraryContent(t1Cover: false))
    #expect(s.covers == 2)
    let art = try ArtworkDB(data: Data(contentsOf: transfer.artworkDBURL))
    #expect(art.images.count == 2)
    #expect(artworkFiles() == ["F1055_1.ithmb", "F1060_1.ithmb", "F1061_1.ithmb", "F1068_1.ithmb"])
    let db = try ITunesDB(data: Data(contentsOf: ipod.databaseURL))
    let m = transfer.loadManifest()
    #expect(db.track(dbid: m.tracks["t1"]!.dbid)?.u32(0x160) == db.track(dbid: m.tracks["t2"]!.dbid)?.u32(0x160))
    #expect(db.track(dbid: m.tracks["t3"]!.dbid)?.u32(0x160) != db.track(dbid: m.tracks["t1"]!.dbid)?.u32(0x160))
    // The database is signed for the classic.
    #expect(try Data(contentsOf: ipod.databaseURL)[0x30] == 1)
  }

  @Test func noArtworkOnModelsWithoutAScreenForIt() throws {
    let ipod = try device(model: "M9282") // 4th generation, monochrome
    let s = try IPodTransfer(device: ipod, out: Captured()).run(libraryContent())
    #expect(s.covers == 0)
    #expect(artworkFiles().isEmpty)
  }
}
