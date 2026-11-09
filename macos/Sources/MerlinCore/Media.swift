import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns arbitrary audio files into what the speaker plays. The speaker's own
/// files are MP3, 44.1 kHz, mono 64 kbps or stereo 128 kbps, each with a
/// 128x128 JPEG cover. MP3s already in that range are copied untouched;
/// anything else is transcoded with ffmpeg (macOS can't encode MP3 itself).
public protocol MediaTools {
  func probe(_ path: URL) throws -> MediaInfo
  func prepareAudio(_ src: URL, _ dest: URL, _ info: MediaInfo) throws -> ImportAction
  /// Any audio file -> MP3 at kbps (44.1 kHz), keeping the tags.
  func encodeMP3(_ src: URL, _ dest: URL, kbps: Int) throws
  /// The file's embedded artwork as an image file at dest; false if it has none.
  func extractCover(_ src: URL, _ dest: URL, _ info: MediaInfo) throws -> Bool
  func folderCover(_ title: String, _ dest: URL) throws
}

public struct MediaInfo {
  public var title: String?
  public var artist: String?
  public var album: String?
  public var trackNumber: Int?
  public var duration: Int
  public var codec: String
  public var sampleRate: Int
  public var channels: Int
  public var bitRate: Int
  public var hasCover: Bool

  public init(title: String?, artist: String? = nil, album: String? = nil, trackNumber: Int? = nil,
              duration: Int, codec: String, sampleRate: Int, channels: Int, bitRate: Int, hasCover: Bool) {
    self.title = title
    self.artist = artist
    self.album = album
    self.trackNumber = trackNumber
    self.duration = duration
    self.codec = codec
    self.sampleRate = sampleRate
    self.channels = channels
    self.bitRate = bitRate
    self.hasCover = hasCover
  }

  public var isSpeakerReady: Bool {
    codec == "mp3" && sampleRate == 44_100 && (1...2).contains(channels) && bitRate > 0 && bitRate <= 192_000
  }
}

public enum ImportAction: String { case copied, transcoded }

public struct Media: MediaTools {
  public static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "ogg", "oga", "opus", "wma", "mp4", "webm", "caf"]
  /// Kept as they are in the library (macOS plays them); the rest is
  /// converted to MP3 at import.
  public static let keptExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "mp4", "caf"]
  /// Bitrate of MP3s made for the library and the iPod (the speaker gets 128k / 64k).
  public static let qualityKbps = 256
  public static let coverSize = 128
  static let defaultCoverColor: UInt32 = 0xF2A900
  static let folderColors: [UInt32] = [0xE4572E, 0x2E86AB, 0x8E44AD, 0x27AE60, 0xD35400, 0xC0392B, 0x16A085, 0x34495E]

  public init() {}

  public static var ffmpeg: String? { Shell.find("ffmpeg") }
  public static var ffprobe: String? { Shell.find("ffprobe") }
  public static var isAvailable: Bool { ffmpeg != nil && ffprobe != nil }

  public static func requireFFmpeg() throws {
    guard isAvailable else { throw MerlinError("ffmpeg is needed to import audio (brew install ffmpeg)") }
  }

  public func probe(_ path: URL) throws -> MediaInfo {
    try Self.requireFFmpeg()
    let out = try Shell.run(Self.ffprobe!, ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", path.path])
    guard out.status == 0, let data = try? JSON.parse(out.text) as? JSONObject else {
      throw MerlinError("can't read \(path.lastPathComponent): \(out.text.split(separator: "\n").last ?? "")")
    }
    let streams = data.objs("streams")
    guard let audio = streams.first(where: { $0.str("codec_type") == "audio" }) else {
      throw MerlinError("\(path.lastPathComponent) has no audio")
    }
    let format = data.obj("format") ?? [:]
    var tags: [String: String] = [:]
    for (k, v) in format.obj("tags") ?? [:] { tags[k.lowercased()] = v as? String }
    for (k, v) in audio.obj("tags") ?? [:] where tags[k.lowercased()] == nil { tags[k.lowercased()] = v as? String }
    func tag(_ key: String) -> String? {
      let v = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return v?.isEmpty == false ? v : nil
    }
    return MediaInfo(
      title: tag("title"),
      artist: tag("artist") ?? tag("album_artist"),
      album: tag("album"),
      trackNumber: tag("track").flatMap { Int($0.split(separator: "/").first ?? "") },
      duration: Int((Double(format.str("duration") ?? "") ?? 0).rounded()),
      codec: audio.str("codec_name") ?? "",
      sampleRate: audio.int("sample_rate"),
      channels: audio.int("channels"),
      bitRate: audio["bit_rate"] != nil ? audio.int("bit_rate") : format.int("bit_rate"),
      hasCover: streams.contains { $0.str("codec_type") == "video" }
    )
  }

  public func prepareAudio(_ src: URL, _ dest: URL, _ info: MediaInfo) throws -> ImportAction {
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    if info.isSpeakerReady {
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.copyItem(at: src, to: dest)
      return .copied
    }
    let mono = info.channels == 1
    try ffmpeg(["-i", src.path, "-map", "0:a:0", "-vn", "-ac", mono ? "1" : "2", "-ar", "44100",
                "-c:a", "libmp3lame", "-b:a", mono ? "64k" : "128k", "-map_metadata", "-1", dest.path])
    return .transcoded
  }

  public func encodeMP3(_ src: URL, _ dest: URL, kbps: Int) throws {
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ffmpeg(["-i", src.path, "-map", "0:a:0", "-vn", "-ar", "44100", "-c:a", "libmp3lame", "-b:a", "\(kbps)k",
                "-map_metadata", "0", "-id3v2_version", "3", "-f", "mp3", dest.path])
  }

  /// The embedded artwork, as a JPEG at its own size.
  public func extractCover(_ src: URL, _ dest: URL, _ info: MediaInfo) throws -> Bool {
    guard info.hasCover else { return false }
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? ffmpeg(["-i", src.path, "-an", "-map", "0:v:0", "-frames:v", "1", "-q:v", "2", "-f", "image2", dest.path])) != nil
      && CoverImage.isImage(dest)
  }

  /// The speaker doesn't show folder names, only covers: the name in white on
  /// a colored square, in the biggest font that fits. Colors come from the
  /// name (CRC-32, like the Ruby version), so folders look distinct but stable.
  public func folderCover(_ title: String, _ dest: URL) throws {
    let color = Self.folderColors[Int(Self.crc32(Array(title.utf8)) % UInt32(Self.folderColors.count))]
    try Self.drawCover(dest, color: color, text: title)
  }

  public static func defaultCover(_ dest: URL) throws {
    try drawCover(dest, color: defaultCoverColor, text: nil)
  }

  private func ffmpeg(_ args: [String]) throws {
    try Self.requireFFmpeg()
    let out = try Shell.run(Self.ffmpeg!, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + args)
    guard out.status == 0 else {
      throw MerlinError("ffmpeg failed: \(out.text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? "unknown error")")
    }
  }

  // MARK: Drawing

  static func drawCover(_ dest: URL, color: UInt32, text: String?) throws {
    let size = coverSize
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw MerlinError("can't draw cover")
    }
    func c(_ shift: UInt32) -> CGFloat { CGFloat((color >> shift) & 0xFF) / 255 }
    ctx.setFillColor(CGColor(srgbRed: c(16), green: c(8), blue: c(0), alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    if let text, !text.isEmpty { drawFitted(text, in: ctx, box: CGRect(x: 8, y: 8, width: size - 16, height: size - 16)) }
    guard let image = ctx.makeImage() else { throw MerlinError("can't draw cover") }

    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw MerlinError("can't write \(dest.lastPathComponent)")
    }
    CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(out) else { throw MerlinError("can't write \(dest.lastPathComponent)") }
  }

  static func font(_ size: CGFloat) -> CTFont {
    for name in ["ArialRoundedMTBold", "Arial-BoldMT"] {
      let f = CTFontCreateWithName(name as CFString, size, nil)
      if CTFontCopyPostScriptName(f) as String == name { return f }
    }
    return CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)!
  }

  static func attributed(_ text: String, _ size: CGFloat) -> NSAttributedString {
    var align = CTTextAlignment.center
    let style = withUnsafeBytes(of: &align) { ptr in
      CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                      value: ptr.baseAddress!)], 1)
    }
    return NSAttributedString(string: text, attributes: [
      kCTFontAttributeName as NSAttributedString.Key: font(size),
      kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
      kCTParagraphStyleAttributeName as NSAttributedString.Key: style,
    ])
  }

  /// Largest font size at which the text wraps (between words) inside box.
  static func fittingSize(_ text: String, box: CGRect) -> CGFloat {
    func fits(_ size: CGFloat) -> Bool {
      let s = attributed(text, size)
      for word in text.split(whereSeparator: \.isWhitespace) { // never break inside a word
        let line = CTLineCreateWithAttributedString(attributed(String(word), size))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(box.width) { return false }
      }
      let setter = CTFramesetterCreateWithAttributedString(s)
      let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: s.length), nil,
                                                                CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
      return needed.height <= box.height
    }
    var lo: CGFloat = 4, hi: CGFloat = 96
    while hi - lo > 0.5 {
      let mid = (lo + hi) / 2
      if fits(mid) { lo = mid } else { hi = mid }
    }
    return lo
  }

  static func drawFitted(_ text: String, in ctx: CGContext, box: CGRect) {
    let size = fittingSize(text, box: box)
    let s = attributed(text, size)
    let setter = CTFramesetterCreateWithAttributedString(s)
    let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: s.length), nil,
                                                              CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
    let rect = CGRect(x: box.minX, y: box.midY - needed.height / 2, width: box.width, height: ceil(needed.height) + 1)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: s.length), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
  }

  /// Standard CRC-32 (zlib's), used to pick folder colors.
  static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes {
      crc ^= UInt32(b)
      for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
  }
}
