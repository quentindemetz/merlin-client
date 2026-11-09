import Foundation
@testable import MerlinCore
import Testing

@Suite final class ID3Tests {
  let dir = tempDir()
  deinit { try? FileManager.default.removeItem(at: dir) }

  let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x42, count: 3000) + [0xFF, 0xD9])
  let audio = silentMP3(frames: 30)

  func frame(_ id: String, _ body: [UInt8], major: UInt8) -> [UInt8] {
    switch major {
    case 2: return Array(id.utf8) + [UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    case 4: return Array(id.utf8) + ID3.toSyncsafe(body.count) + [0, 0] + body
    default: return Array(id.utf8) + ID3.toBE(body.count) + [0, 0] + body
    }
  }

  func file(major: UInt8, frames: [[UInt8]], padding: Int = 100) throws -> URL {
    let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
    let tag = Array("ID3".utf8) + [major, 0, 0] + ID3.toSyncsafe(body.count) + body
    let url = dir.appendingPathComponent("\(UUID().uuidString).mp3")
    try (Data(tag) + audio).write(to: url)
    return url
  }

  /// The audio after the tag is untouched.
  func audioPart(_ url: URL) throws -> Data {
    let d = try Data(contentsOf: url)
    let size = try #require(ID3.tagSize(d.prefix(10)))
    return d.dropFirst(10 + size)
  }

  @Test func addsATagToAFileWithout() throws {
    let url = dir.appendingPathComponent("plain.mp3")
    try audio.write(to: url)
    try ID3.setCover(jpeg, in: url, scratch: dir.appendingPathComponent("s"))
    #expect(ID3.pictures(in: url) == [jpeg])
    #expect(try audioPart(url) == audio)
    #expect(try Data(contentsOf: url)[3] == 3) // ID3v2.3
    #expect(abs(try AudioFacts.read(url).durationMS - 783) < 60)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("s").path))
  }

  @Test func replacesPicturesAndKeepsTheOtherFrames() throws {
    for major: UInt8 in [3, 4] {
      let title = frame("TIT2", [0] + Array("Le loup".utf8), major: major)
      let old = frame("APIC", [0] + Array("image/png".utf8) + [0, 3, 0, 1, 2, 3], major: major)
      let url = try file(major: major, frames: [title, old])
      try ID3.setCover(jpeg, in: url, scratch: dir.appendingPathComponent("s"))
      let d = try Data(contentsOf: url)
      let tag = ID3.parse(head: [UInt8](d.prefix(10)), body: [UInt8](d.dropFirst(10).prefix(ID3.tagSize(d.prefix(10))!)))
      #expect(tag.major == major)
      #expect(tag.frames.first == title)
      #expect(ID3.pictures(in: url) == [jpeg])
      #expect(try audioPart(url) == audio)
    }
  }

  @Test func id3v22UsesPICFrames() throws {
    let title = frame("TT2", [0] + Array("Vieux".utf8), major: 2)
    let url = try file(major: 2, frames: [title, frame("PIC", [0] + Array("PNG".utf8) + [3, 0, 9, 9], major: 2)])
    try ID3.setCover(jpeg, in: url, scratch: dir.appendingPathComponent("s"))
    #expect(ID3.pictures(in: url) == [jpeg])
    #expect(try Data(contentsOf: url)[3] == 2)
    #expect(try audioPart(url) == audio)
  }

  @Test func nilRemovesThePictures() throws {
    let url = try file(major: 3, frames: [frame("APIC", [0] + Array("image/jpeg".utf8) + [0, 3, 0, 7], major: 3)])
    try ID3.setCover(nil, in: url, scratch: dir.appendingPathComponent("s"))
    #expect(ID3.pictures(in: url).isEmpty)
    #expect(try audioPart(url) == audio)
  }

  @Test func aDamagedTagIsReplaced() throws {
    // A frame claiming more bytes than the tag holds.
    let url = try file(major: 3, frames: [Array("TIT2".utf8) + ID3.toBE(5000) + [0, 0, 0, 65]], padding: 0)
    try ID3.setCover(jpeg, in: url, scratch: dir.appendingPathComponent("s"))
    #expect(ID3.pictures(in: url) == [jpeg])
    #expect(try audioPart(url) == audio)
  }

  @Test func unsynchronisedV23Tags() throws {
    // The frame holds 4 bytes; stored unsynchronised, FF gets a 00 after it.
    let real = Array("TIT2".utf8) + ID3.toBE(4) + [0, 0] + [0, 0x41, 0xFF, 0x42]
    let stored = Array("TIT2".utf8) + ID3.toBE(4) + [0, 0] + [0, 0x41, 0xFF, 0x00, 0x42]
    let url = try file(major: 3, frames: [stored])
    var d = try Data(contentsOf: url)
    d[5] = 0x80 // unsynchronisation flag
    try d.write(to: url)
    try ID3.setCover(jpeg, in: url, scratch: dir.appendingPathComponent("s"))
    #expect(ID3.pictures(in: url) == [jpeg])
    d = try Data(contentsOf: url)
    #expect(d[5] == 0) // written without unsynchronisation
    let tag = ID3.parse(head: [UInt8](d.prefix(10)), body: [UInt8](d.dropFirst(10).prefix(ID3.tagSize(d.prefix(10))!)))
    #expect(tag.frames.first == real)
    #expect(try audioPart(url) == audio)
  }
}

@Suite final class EmbeddedArtworkTests {
  let dir = tempDir()
  deinit { try? FileManager.default.removeItem(at: dir) }

  @Test func storedTracksCarryTheirCover() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let src = dir.appendingPathComponent("a.mp3")
    try silentMP3(frames: 20).write(to: src)
    // Its own cover.
    let (t, _) = try lib.importFile(src, into: .byAlbum(section: "Musique"), media: TaggedMedia(album: "A", cover: true))
    #expect(ID3.pictures(in: lib.url(t.audio)) == [try Data(contentsOf: lib.url(t.cover!))])
    #expect(lib.track(t.id)?.size == MediaLibrary.size(lib.url(t.audio)))

    // None of its own: the folder's.
    let image = dir.appendingPathComponent("folder.png")
    try solidImage(image, width: 300, height: 300, rgb: (0, 1, 0), png: true)
    let folder = try lib.addFolder("Contes", section: "Histoires", cover: image)
    let (u, _) = try lib.importFile(src, into: .folder(folder.id), media: TaggedMedia())
    #expect(ID3.pictures(in: lib.url(u.audio)) == [try Data(contentsOf: lib.url(folder.cover!))])

    // The folder's cover changes, then goes away.
    try solidImage(image, width: 300, height: 300, rgb: (1, 0, 0), png: true)
    try lib.setFolderCover(folder.id, image: image)
    #expect(lib.tracksUsingFolderCover(folder.id) == [u.id])
    try lib.embedArtwork([u.id])
    #expect(ID3.pictures(in: lib.url(u.audio)) == [try Data(contentsOf: lib.url(folder.cover!))])
    try lib.setFolderCover(folder.id, image: nil)
    try lib.embedArtwork([u.id])
    #expect(ID3.pictures(in: lib.url(u.audio)).isEmpty)
  }

  @Test func anImportedAlbumTakesItsTracksArtwork() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let src = dir.appendingPathComponent("a.mp3")
    try silentMP3(frames: 20).write(to: src)
    // The first track has no artwork, the second has.
    let (bare, _) = try lib.importFile(src, into: .byAlbum(section: "Musique"), media: TaggedMedia(album: "Multitude"))
    #expect(lib.folder(bare.folderID)?.cover == nil)
    let (art, _) = try lib.importFile(src, into: .byAlbum(section: "Musique"), media: TaggedMedia(album: "Multitude", cover: true))
    let folder = try #require(lib.folder(art.folderID))
    #expect(folder.id == bare.folderID)
    #expect(folder.cover == "\(folder.id).jpg")
    let jpeg = try Data(contentsOf: lib.url(folder.cover!))
    #expect(jpeg == (try Data(contentsOf: lib.url(art.cover!))))
    #expect(ID3.pictures(in: lib.url(bare.audio)) == [jpeg], "the earlier track gets it inside its file too")

    // Folders made before this: filled when the library opens.
    try lib.setFolderCover(folder.id, image: nil)
    #expect(lib.adoptCovers() == [bare.id])
    #expect(lib.folder(folder.id)?.cover != nil)
    #expect(lib.adoptCovers().isEmpty)
  }

  @Test func onlyOldLibrariesNeedTheOneTimePass() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("lib"))
    let src = dir.appendingPathComponent("a.mp3")
    try silentMP3(frames: 20).write(to: src)
    try lib.importFile(src, into: .byAlbum(section: "Musique"), media: TaggedMedia())
    #expect(lib.tracksWithoutEmbeddedArtwork().isEmpty)
    lib.setMeta("artwork_embedded", nil) // as a library from before
    #expect(lib.tracksWithoutEmbeddedArtwork().count == 1)
    lib.markArtworkEmbedded()
    #expect(lib.tracksWithoutEmbeddedArtwork().isEmpty)
  }
}
