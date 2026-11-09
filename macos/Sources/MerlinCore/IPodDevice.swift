import Foundation
import IOKit

/// iPod generations, from libgpod's model table (itdb_device.c).
public enum IPodGeneration: String, CaseIterable, Sendable {
  case first, second, third, fourth, photo, mini1, mini2, shuffle1, shuffle2, shuffle3, shuffle4
  case nano1, nano2, nano3, nano4, nano5, nano6, video1, video2, classic1, classic2, classic3
  case touch1, touch2, touch3, touch4, iphone1, iphone2, iphone3, iphone4, ipad1

  public var name: String {
    switch self {
    case .first: "iPod (1st generation)"
    case .second: "iPod (2nd generation)"
    case .third: "iPod (3rd generation)"
    case .fourth: "iPod (4th generation)"
    case .photo: "iPod photo"
    case .mini1: "iPod mini (1st generation)"
    case .mini2: "iPod mini (2nd generation)"
    case .shuffle1, .shuffle2, .shuffle3, .shuffle4: "iPod shuffle"
    case .nano1: "iPod nano (1st generation)"
    case .nano2: "iPod nano (2nd generation)"
    case .nano3: "iPod nano (3rd generation)"
    case .nano4: "iPod nano (4th generation)"
    case .nano5: "iPod nano (5th generation)"
    case .nano6: "iPod nano (6th generation)"
    case .video1: "iPod video (5th generation)"
    case .video2: "iPod video (5.5th generation)"
    case .classic1, .classic2, .classic3: "iPod classic"
    case .touch1, .touch2, .touch3, .touch4: "iPod touch"
    case .iphone1, .iphone2, .iphone3, .iphone4: "iPhone"
    case .ipad1: "iPad"
    }
  }

  /// The database checksum the iPod insists on (itdb_device_get_checksum_type).
  public var checksum: IPodChecksum {
    switch self {
    case .classic1, .classic2, .classic3, .nano3, .nano4: .hash58
    case .nano5, .nano6, .touch1, .touch2, .touch3, .touch4, .iphone1, .iphone2, .iphone3, .iphone4, .ipad1: .unsupported
    default: .none
    }
  }

  public var isShuffle: Bool { [.shuffle1, .shuffle2, .shuffle3, .shuffle4].contains(self) }

  /// model number (ModelNumStr without its first letter) -> capacity (GB), generation
  static let models: [String: (Double, IPodGeneration)] = {
    var out: [String: (Double, IPodGeneration)] = [:]
    for item in table.split(separator: " ") {
      let f = item.split(separator: ":")
      if f.count == 3, let gb = Double(f[1]), let gen = IPodGeneration(rawValue: String(f[2])) { out[String(f[0])] = (gb, gen) }
    }
    return out
  }()

  private static let table =
    "8513:5:first 8541:5:first 8697:5:first 8709:10:first 8737:10:second 8740:10:second 8738:20:second " +
    "8741:20:second 8976:10:third 8946:15:third 9460:15:third 9244:20:third 8948:30:third 9245:40:third " +
    "9282:20:fourth 9787:25:fourth 9268:40:fourth 9160:4:mini1 9436:4:mini1 9435:4:mini1 9434:4:mini1 " +
    "9437:4:mini1 9800:4:mini2 9802:4:mini2 9804:4:mini2 9806:4:mini2 9801:6:mini2 9803:6:mini2 9805:6:mini2 " +
    "9807:6:mini2 A079:20:photo A127:20:photo 9829:30:photo 9585:40:photo 9830:60:photo 9586:60:photo " +
    "9724:0.5:shuffle1 9725:1:shuffle1 A546:1:shuffle2 A947:1:shuffle2 A949:1:shuffle2 A951:1:shuffle2 " +
    "A953:1:shuffle2 C167:1:shuffle2 B225:1:shuffle2 B233:1:shuffle2 B231:1:shuffle2 B227:1:shuffle2 " +
    "B228:1:shuffle2 B229:1:shuffle2 B518:2:shuffle2 B520:2:shuffle2 B522:2:shuffle2 B524:2:shuffle2 " +
    "B526:2:shuffle2 C306:2:shuffle3 C323:2:shuffle3 C381:2:shuffle3 C384:2:shuffle3 C387:2:shuffle3 " +
    "B867:4:shuffle3 C164:4:shuffle3 C303:4:shuffle3 C307:4:shuffle3 C328:4:shuffle3 C331:4:shuffle3 " +
    "C584:2:shuffle4 C585:2:shuffle4 C749:2:shuffle4 C750:2:shuffle4 C751:2:shuffle4 A350:1:nano1 A352:1:nano1 " +
    "A004:2:nano1 A099:2:nano1 A005:4:nano1 A107:4:nano1 A002:30:video1 A146:30:video1 A003:60:video1 " +
    "A147:60:video1 A452:30:video1 A444:30:video2 A446:30:video2 A664:30:video2 A448:80:video2 A450:80:video2 " +
    "A477:2:nano2 A426:4:nano2 A428:4:nano2 A487:4:nano2 A489:4:nano2 A725:4:nano2 A726:8:nano2 A497:8:nano2 " +
    "E436:40:fourth S492:30:photo B029:80:classic1 B147:80:classic1 B145:160:classic1 B150:160:classic1 " +
    "B562:120:classic2 B565:120:classic2 C293:160:classic3 C297:160:classic3 A978:4:nano3 A980:8:nano3 " +
    "B261:8:nano3 B249:8:nano3 B253:8:nano3 B257:8:nano3 B480:4:nano4 B651:4:nano4 B654:4:nano4 B657:4:nano4 " +
    "B660:4:nano4 B663:4:nano4 B666:4:nano4 B598:8:nano4 B732:8:nano4 B735:8:nano4 B739:8:nano4 B742:8:nano4 " +
    "B745:8:nano4 B748:8:nano4 B751:8:nano4 B754:8:nano4 B903:16:nano4 B905:16:nano4 B907:16:nano4 " +
    "B909:16:nano4 B911:16:nano4 B913:16:nano4 B915:16:nano4 B917:16:nano4 B918:16:nano4 C027:8:nano5 " +
    "C031:8:nano5 C034:8:nano5 C037:8:nano5 C040:8:nano5 C043:8:nano5 C046:8:nano5 C049:8:nano5 C050:8:nano5 " +
    "C060:16:nano5 C062:16:nano5 C064:16:nano5 C066:16:nano5 C068:16:nano5 C070:16:nano5 C072:16:nano5 " +
    "C074:16:nano5 C075:16:nano5 C525:8:nano6 C688:8:nano6 C689:8:nano6 C690:8:nano6 C691:8:nano6 C692:8:nano6 " +
    "C693:8:nano6 C526:16:nano6 C694:16:nano6 C695:16:nano6 C696:16:nano6 C697:16:nano6 C698:16:nano6 " +
    "C699:16:nano6 A623:8:touch1 A627:16:touch1 B376:32:touch1 B528:8:touch2 B531:16:touch2 B533:32:touch2 " +
    "C086:8:touch2 C008:32:touch3 C011:64:touch3 C540:8:touch4 C544:32:touch4 C547:64:touch4 A501:4:iphone1 " +
    "A712:8:iphone1 B384:16:iphone1 B046:8:iphone2 B500:16:iphone2 B048:16:iphone2 B496:16:iphone2 " +
    "C131:16:iphone3 C133:32:iphone3 C134:32:iphone3 C603:16:iphone4 C605:32:iphone4 B292:16:ipad1 " +
    "B293:32:ipad1 B294:64:ipad1 C349:16:ipad1 C496:32:ipad1 C497:64:ipad1 "
}

public enum IPodChecksum: Sendable { case none, hash58, unsupported }

/// A mounted iPod (disk mode): its folders, model and FireWire ID, as
/// libgpod's Itdb_Device reads them.
public struct IPodDevice: Identifiable, Hashable, Sendable {
  public let mountPoint: URL
  public let volumeName: String
  /// e.g. "A147" (SysInfo's ModelNumStr without its first letter).
  public let modelNumber: String?
  public let generation: IPodGeneration?
  public let capacityGB: Double?
  let firewireGUID: String?
  let dbVersion: Int?
  /// Cover sizes listed by the iPod itself (SysInfoExtended), if any.
  let extendedArtwork: [ArtworkFormat]?

  public var id: String { mountPoint.path }

  public var control: URL { mountPoint.appendingPathComponent("iPod_Control") }
  public var itunesDir: URL { control.appendingPathComponent("iTunes") }
  public var musicDir: URL { control.appendingPathComponent("Music") }
  public var databaseURL: URL { itunesDir.appendingPathComponent("iTunesDB") }
  var deviceDir: URL { control.appendingPathComponent("Device") }

  public var modelName: String {
    let name = generation?.name ?? "iPod"
    // An iPod whose disk was upgraded (flash cards…) is bigger than its model.
    let values = try? mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey, .isVolumeKey])
    let total = values?.isVolume == true ? values?.volumeTotalCapacity ?? 0 : 0
    if let gb = capacityGB, Double(total) > gb * 1.25e9 {
      return "\(name), \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)) (upgraded)"
    }
    guard let gb = capacityGB, gb > 0 else { return name }
    return gb < 1 ? "\(name), \(Int(gb * 1000)) MB" : "\(name), \(gb == gb.rounded() ? String(Int(gb)) : String(gb)) GB"
  }

  /// Mounted volumes that look like an iPod in disk mode.
  public static func connected() -> [IPodDevice] {
    let keys: [URLResourceKey] = [.volumeNameKey]
    let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return volumes.compactMap { IPodDevice(mountPoint: $0) }
  }

  public init?(mountPoint: URL) {
    var isDir: ObjCBool = false
    let control = mountPoint.appendingPathComponent("iPod_Control")
    guard FileManager.default.fileExists(atPath: control.path, isDirectory: &isDir), isDir.boolValue else { return nil }
    self.mountPoint = mountPoint
    volumeName = (try? mountPoint.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? mountPoint.lastPathComponent

    let device = control.appendingPathComponent("Device")
    let sysInfo = Self.parseSysInfo(device.appendingPathComponent("SysInfo"))
    let extended = (try? Data(contentsOf: device.appendingPathComponent("SysInfoExtended")))
      .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }

    var number = sysInfo["ModelNumStr"]
    if let n = number, let first = n.unicodeScalars.first, CharacterSet.letters.contains(first) { number = String(n.dropFirst()) }
    number = number.map { String($0.prefix(4)) }
    modelNumber = number
    let known = number.flatMap { IPodGeneration.models[$0] }
    generation = known?.1
    capacityGB = known?.0
    dbVersion = extended?["DBVersion"] as? Int
    extendedArtwork = (extended?["AlbumArt"] as? [[String: Any]]).map(ArtworkFormat.fromSysInfoExtended).flatMap { $0.isEmpty ? nil : $0 }
    firewireGUID = (extended?["FireWireGUID"] as? String) ?? sysInfo["FirewireGuid"]
      ?? Self.usbSerialNumber(volume: mountPoint)
  }

  /// "Key: value" lines.
  static func parseSysInfo(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      guard let colon = line.firstIndex(of: ":") else { continue }
      out[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return out
  }

  /// Stable across mounts and renames: the FireWire GUID, else the volume name.
  public var syncID: String {
    firewireID.map { $0.map { String(format: "%02X", $0) }.joined() } ?? volumeName
  }

  /// The FireWire GUID as bytes (libgpod's itdb_device_get_hex_uuid).
  public var firewireID: [UInt8]? {
    guard var s = firewireGUID?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    if s.lowercased().hasPrefix("0x") { s = String(s.dropFirst(2)) }
    guard s.count % 2 == 0, s.count <= 40, s.allSatisfy(\.isHexDigit) else { return nil }
    var bytes: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
      let j = s.index(i, offsetBy: 2)
      bytes.append(UInt8(s[i..<j], radix: 16)!)
      i = j
    }
    return bytes
  }

  /// Without SysInfoExtended, the GUID is the iPod's USB serial number
  /// (16 hex digits on the models that need it).
  static func usbSerialNumber(volume: URL) -> String? {
    var fs = statfs()
    guard statfs(volume.path, &fs) == 0 else { return nil }
    let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    guard from.hasPrefix("/dev/") else { return nil }
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, String(from.dropFirst(5))) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    let serial = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "USB Serial Number" as CFString, kCFAllocatorDefault, options) as? String
    guard let serial, serial.count == 16, serial.allSatisfy(\.isHexDigit) else { return nil }
    return serial
  }

  /// Which checksum the database needs: SysInfoExtended knows best, then the
  /// model table, then what iTunes wrote last time.
  public func checksum(existing db: ITunesDB?) -> IPodChecksum {
    if FileManager.default.fileExists(atPath: itunesDir.appendingPathComponent("iTunesCDB").path) { return .unsupported }
    if let v = dbVersion { return v <= 2 ? .none : v == 3 ? .hash58 : .unsupported }
    if let g = generation, g.checksum != .none { return g.checksum }
    if let db {
      if db.hashingScheme >= 2 || db.hasNewerChecksum { return .unsupported }
      if db.hashingScheme == 1 { return .hash58 }
    }
    return .none
  }

  /// Why Merlin can't write to this iPod, if it can't.
  public func problem(existing db: ITunesDB?) -> String? {
    // The model decides; an iTunesSD file is only a clue when the model is
    // unknown (other tools leave one on iPods with a screen too).
    let looksLikeShuffle = generation.map(\.isShuffle)
      ?? FileManager.default.fileExists(atPath: itunesDir.appendingPathComponent("iTunesSD").path)
    if looksLikeShuffle {
      return "An iPod shuffle has no screen and its own database format; Merlin can't fill it."
    }
    switch checksum(existing: db) {
    case .unsupported:
      return "This \(generation?.name ?? "iPod") signs its database in a way only iTunes/Finder can reproduce."
    case .hash58 where firewireID == nil:
      return "This \(generation?.name ?? "iPod") needs a checksum made from its FireWire ID, which Merlin couldn't read."
    default:
      return nil
    }
  }

  /// The cover sizes to write (none: the iPod shows no artwork).
  public var coverFormats: [ArtworkFormat] { extendedArtwork ?? generation?.coverFormats ?? [] }
  var sparseArtwork: Bool { generation?.sparseArtwork ?? false }
  var artworkDir: URL { control.appendingPathComponent("Artwork") }

  public var freeSpace: Int64 {
    let values = try? mountPoint.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
    return Int64(values?.volumeAvailableCapacity ?? 0)
  }

  public var totalSpace: Int64 {
    Int64((try? mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity ?? 0)
  }
}
