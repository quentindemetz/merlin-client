import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cover pictures: the library keeps one JPEG per track or folder, at most
/// `librarySize` pixels on its longest side (enough for an iPod classic);
/// the speaker gets 128x128 crops made from those at sync time.
public enum CoverImage {
  public static let librarySize = 600

  public static func isImage(_ url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return CGImageSourceGetCount(src) > 0
  }

  /// Any image file -> JPEG no bigger than maxPixels, aspect kept.
  public static func normalize(_ src: URL, to dest: URL, maxPixels: Int = librarySize) throws {
    guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
      throw MerlinError("\(src.lastPathComponent) is not an image")
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw MerlinError("can't read the image \(src.lastPathComponent)")
    }
    try writeJPEG(flatten(image, width: image.width, height: image.height, fill: false), to: dest)
  }

  /// A size x size crop filling the square (what the speaker shows).
  public static func square(_ src: URL, to dest: URL, size: Int = Media.coverSize) throws {
    guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw MerlinError("can't read the image \(src.lastPathComponent)")
    }
    try writeSpeakerJPEG(flatten(image, width: size, height: size, fill: true), to: dest)
  }

  /// Whether two covers show the same picture: compared on 16x16
  /// thumbnails, so re-encoded copies of the same art still match.
  public static func looksSame(_ a: URL, _ b: URL) -> Bool {
    guard let x = fingerprint(a), let y = fingerprint(b), x.count == y.count else { return false }
    let diff = zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    return Double(diff) / Double(x.count) <= 6 // out of 255
  }

  static func fingerprint(_ url: URL, side: Int = 16) -> [UInt8]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let data = ctx.data else { return nil }
    let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4)
    return bytes.enumerated().filter { $0.offset % 4 != 3 }.map(\.element) // RGB
  }

  /// Puts `number` on the cover, in a round badge at the bottom right
  /// (tracks of an album sharing its art stay apart on the speaker).
  public static func addNumber(_ number: Int, to url: URL) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw MerlinError("can't read the image \(url.lastPathComponent)")
    }
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw MerlinError("can't draw the cover")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let side = Double(min(w, h)), d = side * 0.47, margin = side * 0.04
    let circle = CGRect(x: Double(w) - d - margin, y: margin, width: d, height: d) // CG's origin is bottom left
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
    ctx.fillEllipse(in: circle)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    ctx.setLineWidth(max(1, side / 64))
    ctx.strokeEllipse(in: circle.insetBy(dx: side / 128, dy: side / 128))
    let text = String(number)
    let box = circle.insetBy(dx: d * (text.count > 2 ? 0.14 : 0.2), dy: d * 0.2)
    Media.drawFitted(text, in: ctx, box: box)
    guard let out = ctx.makeImage() else { throw MerlinError("can't draw the cover") }
    try writeSpeakerJPEG(out, to: url)
  }

  /// A cover for the speaker. Its screen shows 16-bit colour (RGB565): the
  /// firmware's LVGL drops the low bits (5 for red and blue, 6 for green).
  /// A colour near the edge of one of those steps flips to the next with the
  /// slightest JPEG noise, so flat areas and edges speckle on the speaker. So
  /// every colour is moved to the middle of its step (which the screen
  /// can't tell apart from the original) and saved at quality 1.0, which is
  /// also the only quality where ImageIO keeps full colour resolution (4:4:4).
  /// About 0.5% of pixels still flip, against 15-19% for a quality 0.95 file.
  static func writeSpeakerJPEG(_ image: CGImage, to dest: URL) throws {
    try writeJPEG(snappedToRGB565(image), to: dest, quality: 1.0)
  }

  /// Each channel moved to the middle of its RGB565 step: red and blue to
  /// 8k + 4, green to 4k + 2.
  static func snappedToRGB565(_ image: CGImage) throws -> CGImage {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let data = ctx.data else {
      throw MerlinError("can't draw the cover")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = data.assumingMemoryBound(to: UInt8.self)
    for i in stride(from: 0, to: w * h * 4, by: 4) {
      px[i] = Self.snap(px[i], bits: 5)
      px[i + 1] = Self.snap(px[i + 1], bits: 6)
      px[i + 2] = Self.snap(px[i + 2], bits: 5)
    }
    guard let out = ctx.makeImage() else { throw MerlinError("can't draw the cover") }
    return out
  }

  static func snap(_ v: UInt8, bits: Int) -> UInt8 {
    let step = 1 << (8 - bits)
    return UInt8(min(Int(v) / step * step + step / 2, 255))
  }

  /// Draws on an opaque sRGB canvas (no alpha in JPEGs; transparent PNGs
  /// get a white background).
  static func flatten(_ image: CGImage, width: Int, height: Int, fill: Bool) throws -> CGImage {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw MerlinError("can't draw the cover")
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    var rect = CGRect(x: 0, y: 0, width: width, height: height)
    if fill {
      let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
      let w = Double(image.width) * scale, h = Double(image.height) * scale
      rect = CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
    }
    ctx.draw(image, in: rect)
    guard let out = ctx.makeImage() else { throw MerlinError("can't draw the cover") }
    return out
  }

  static func writeJPEG(_ image: CGImage, to dest: URL, quality: Double = 0.9) throws {
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw MerlinError("can't write \(dest.lastPathComponent)")
    }
    CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(out) else { throw MerlinError("can't write \(dest.lastPathComponent)") }
  }
}
