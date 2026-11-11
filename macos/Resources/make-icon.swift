// Renders AppIcon.svg (next to this script) at every icon size:
// usage `swift make-icon.swift <out.iconset>`. AppKit draws SVG natively.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let svg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AppIcon.svg")
guard let icon = NSImage(contentsOf: svg) else { fatalError("can't read \(svg.path)") }

func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
  try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
  try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
