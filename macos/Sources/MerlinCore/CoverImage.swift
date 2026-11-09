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
    try writeJPEG(flatten(image, width: size, height: size, fill: true), to: dest)
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
