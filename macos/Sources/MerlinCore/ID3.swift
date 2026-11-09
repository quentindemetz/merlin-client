import Foundation

/// Just enough ID3v2 to put a cover in an MP3: the tag is rebuilt with its
/// frames kept as they are, except picture frames (APIC / PIC), which are
/// replaced by the given JPEG. A file without a tag gets an ID3v2.3 one.
/// A tag that can't be parsed is replaced by one holding only the picture.
public enum ID3 {
  struct Tag {
    var major: UInt8 = 3
    var frames: [[UInt8]] = [] // raw frames (header + body)
    var end = 0 // where the audio starts
  }

  /// Sets the front cover (nil removes every picture). Streams the audio, so
  /// big files are fine; `scratch` is where the new file is written before
  /// it replaces the old one.
  public static func setCover(_ jpeg: Data?, in url: URL, scratch: URL) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let head = try handle.read(upToCount: 10) ?? Data()
    var tag = Tag()
    if let size = tagSize(head) {
      let body = [UInt8](try handle.read(upToCount: size) ?? Data())
      tag = parse(head: [UInt8](head), body: body)
    }
    tag.frames.removeAll { isPicture($0, major: tag.major) }
    if let jpeg { tag.frames.append(pictureFrame(jpeg, major: tag.major)) }

    FileManager.default.createFile(atPath: scratch.path, contents: nil)
    let out = try FileHandle(forWritingTo: scratch)
    do {
      try out.write(contentsOf: Data(serialize(tag)))
      try handle.seek(toOffset: UInt64(tag.end))
      while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        try out.write(contentsOf: chunk)
      }
      try out.close()
    } catch {
      try? out.close()
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
  }

  /// The pictures in the file's tag (JPEG/PNG bytes), for checks.
  public static func pictures(in url: URL) -> [Data] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 10)) ?? Data()
    guard let size = tagSize(head), let body = try? handle.read(upToCount: size) else { return [] }
    let tag = parse(head: [UInt8](head), body: [UInt8](body))
    return tag.frames.filter { isPicture($0, major: tag.major) }.compactMap { pictureData($0, major: tag.major) }
  }

  // MARK: Reading

  /// The size of the tag body after the 10-byte header, if there is a tag.
  static func tagSize(_ head: Data) -> Int? {
    let h = [UInt8](head)
    guard h.count == 10, h[0] == 0x49, h[1] == 0x44, h[2] == 0x33, h[3] < 0xFF, h[4] < 0xFF,
          h[6...9].allSatisfy({ $0 < 0x80 }) else { return nil }
    return syncsafe(h[6...9])
  }

  static func parse(head: [UInt8], body raw: [UInt8]) -> Tag {
    let major = head[3], flags = head[5]
    var tag = Tag(major: major, end: 10 + raw.count + (major == 4 && flags & 0x10 != 0 ? 10 : 0))
    guard (2...4).contains(major) else {
      tag.major = 3 // unknown version: start over
      return tag
    }
    var body = raw
    if major < 4 && flags & 0x80 != 0 { body = deunsynchronise(body) }
    var pos = 0
    if flags & 0x40 != 0 && major >= 3 { // extended header: dropped
      guard body.count >= 4 else { return tag }
      pos = major == 3 ? 4 + be(body[0..<4]) : syncsafe(body[0..<4])
    }
    let idLength = major == 2 ? 3 : 4, headerLength = major == 2 ? 6 : 10
    var frames: [[UInt8]] = []
    while pos + headerLength <= body.count {
      let id = body[pos..<pos + idLength]
      guard id.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else { break } // padding
      let sizeBytes = body[pos + idLength..<pos + idLength + (major == 2 ? 3 : 4)]
      let size = major == 4 ? syncsafe(sizeBytes) : be(sizeBytes)
      let end = pos + headerLength + size
      guard size >= 0, end <= body.count else { return Tag(major: major, frames: [], end: tag.end) } // damaged
      frames.append(Array(body[pos..<end]))
      pos = end
    }
    tag.frames = frames
    return tag
  }

  static func isPicture(_ frame: [UInt8], major: UInt8) -> Bool {
    major == 2 ? frame.starts(with: Array("PIC".utf8)) : frame.starts(with: Array("APIC".utf8))
  }

  static func pictureData(_ frame: [UInt8], major: UInt8) -> Data? {
    let body = Array(frame.dropFirst(major == 2 ? 6 : 10))
    guard body.count > 4 else { return nil }
    let utf16 = body[0] == 1 || body[0] == 2
    var i: Int
    if major == 2 {
      i = 1 + 3 + 1 // encoding, format, type
    } else {
      guard let zero = body[1...].firstIndex(of: 0) else { return nil }
      i = zero + 1 + 1 // MIME, type
    }
    // Description, terminated by one or two zero bytes.
    while i < body.count {
      if utf16 {
        if i + 1 < body.count, body[i] == 0, body[i + 1] == 0 { i += 2; break }
        i += 2
      } else {
        if body[i] == 0 { i += 1; break }
        i += 1
      }
    }
    return i <= body.count ? Data(body[i...]) : nil
  }

  // MARK: Writing

  static func pictureFrame(_ jpeg: Data, major: UInt8) -> [UInt8] {
    if major == 2 {
      let body = [0] + Array("JPG".utf8) + [3, 0] + [UInt8](jpeg) // latin-1, JPG, front cover, no description
      return Array("PIC".utf8) + [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    }
    let body = [0] + Array("image/jpeg".utf8) + [0, 3, 0] + [UInt8](jpeg)
    let size = major == 4 ? toSyncsafe(body.count) : toBE(body.count)
    return Array("APIC".utf8) + size + [0, 0] + body
  }

  static let padding = 512

  static func serialize(_ tag: Tag) -> [UInt8] {
    let frames = tag.frames.flatMap { $0 }
    return Array("ID3".utf8) + [tag.major, 0, 0] + toSyncsafe(frames.count + padding) + frames + [UInt8](repeating: 0, count: padding)
  }

  // MARK: Integers

  static func syncsafe(_ b: ArraySlice<UInt8>) -> Int { b.reduce(0) { $0 << 7 | Int($1 & 0x7F) } }
  static func be(_ b: ArraySlice<UInt8>) -> Int { b.reduce(0) { $0 << 8 | Int($1) } }
  static func toSyncsafe(_ n: Int) -> [UInt8] { [21, 14, 7, 0].map { UInt8(n >> $0 & 0x7F) } }
  static func toBE(_ n: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(n >> $0 & 0xFF) } }

  /// Undoes ID3v2.3 unsynchronisation (FF 00 -> FF).
  static func deunsynchronise(_ b: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(b.count)
    var i = 0
    while i < b.count {
      out.append(b[i])
      if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0 { i += 1 }
      i += 1
    }
    return out
  }
}
