import Foundation
import IOKit

/// iPods seen on USB, whether or not macOS mounted them: the iPod screen
/// can then say "plugged in but no disk" instead of "connect an iPod".
public struct IPodUSB: Equatable, Sendable {
  public let name: String
  public let serial: String?
  /// The whole disk's BSD name (disk4) when the iPod presented one.
  public let bsdName: String?

  public var hasDisk: Bool { bsdName != nil }

  static let appleVendor = 0x05AC

  public static func connected() -> [IPodUSB] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var out: [IPodUSB] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      func prop(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      }
      guard (prop("idVendor") as? Int) == appleVendor,
            let name = (prop("USB Product Name") ?? prop("kUSBProductString")) as? String,
            name.localizedCaseInsensitiveContains("iPod") else { continue }
      // The whole disk sits somewhere below the USB device, if there is one.
      let bsd = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively)) as? String
      out.append(IPodUSB(name: name, serial: prop("USB Serial Number") as? String, bsdName: bsd))
    }
    return out
  }

  /// Asks macOS to mount every volume of the iPod's disk.
  public func mount() throws {
    guard let bsdName else { throw MerlinError("the iPod has no disk to mount") }
    let out = try Shell.run("/usr/sbin/diskutil", ["mountDisk", bsdName])
    guard out.status == 0 else {
      let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.contains("Failed to find disk") {
        throw MerlinError("the iPod's disk went away before it could be mounted — Finder probably released it. Turn on “Enable disk use” for the iPod in Finder, then plug it in again.")
      }
      throw MerlinError("diskutil couldn't mount the iPod: \(text)")
    }
  }
}
