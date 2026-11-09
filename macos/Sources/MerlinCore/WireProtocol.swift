import Foundation

/// Wire format of the speaker's TCP protocol (192.168.4.1:50000).
///
/// Every frame is `[len:u8] [cmd:u8] [payload...] [crc32:u32 LE]`, where
/// len = payload.count + 5 (the frame is len + 1 bytes long) and crc32 is
/// CRC-32/MPEG-2 (poly 0x04C11DB7, init 0xFFFFFFFF, no reflection, no final
/// xor) over cmd + payload.
///
/// File contents (uploads and downloads) are NOT framed: after the speaker
/// accepts a transfer, raw bytes are streamed on the same socket.
public enum WireProtocol {
  public enum Cmd {
    public static let uploadFile: UInt8 = 1
    public static let ping: UInt8 = 2
    public static let availableSpace: UInt8 = 3
    public static let totalSize: UInt8 = 4
    public static let firmwareVersion: UInt8 = 5
    public static let updatePlaylist: UInt8 = 6
    public static let updateFirmware: UInt8 = 7
    public static let setDate: UInt8 = 8
    public static let endSynchronization: UInt8 = 9
    public static let reset: UInt8 = 10
    public static let getFile: UInt8 = 13
    public static let batteryState: UInt8 = 14
    public static let setWifi: UInt8 = 16
    public static let getDate: UInt8 = 27
    public static let setEnablingHours: UInt8 = 29
    public static let macAddress: UInt8 = 30
    public static let searchFile: UInt8 = 31
    public static let unknown: UInt8 = 0xFF

    static let names: [UInt8: String] = [
      1: "upload_file", 2: "ping", 3: "available_space", 4: "total_size", 5: "firmware_version",
      6: "update_playlist", 7: "update_firmware", 8: "set_date", 9: "end_synchronization", 10: "reset",
      13: "get_file", 14: "battery_state", 16: "set_wifi", 27: "get_date", 29: "set_enabling_hours",
      30: "mac_address", 31: "search_file", 0xFF: "unknown",
    ]

    public static func name(_ cmd: UInt8) -> String { names[cmd] ?? "cmd\(cmd)" }
  }

  /// Status codes, keyed by the command whose response carries them.
  public static let statuses: [UInt8: [String]] = [
    Cmd.uploadFile: [
      "SUCCESS", "SHA256_VALID", "NOT_ENOUGH_SPACE", "FILENAME_TOO_LARGE", "SHA256_INVALID",
      "BAD_LENGTH_CMD", "TIMEOUT", "FAIL_CREATE_FILE",
    ],
    Cmd.updatePlaylist: [
      "SUCCESS", "BAD_FILENAME_LEN", "BAD_EXTENSION_FILE", "FILE_NOT_FOUND", "FAIL_MINIFIER",
      "FAIL_OPEN_JSON", "FAIL_OPEN_BINARY", "ROOT_ELEMENT_IS_NOT_ARRAY",
      "BAD_ROOT_CHILD_QUANTITY", "MISSING_FIELD", "BAD_UUID_FIELD", "UUID_TOO_LARGE",
      "BAD_TITLE_FIELD", "TITLE_TOO_LARGE", "FAIL_ADD_ELEMENT", "FAIL_RENAME_BIN_FILE",
      "INVALID_TYPE_IN_BINARY_FILE", "IMAGE_NOT_FOUND", "MUSIC_NOT_FOUND",
      "FAVORITES_NOT_FOUND", "TOO_MANY_FAVORITES", "FAIL_CREATE_FAV_FILE",
      "FAIL_OPEN_FAV_FILE", "BAD_FAV_FORMAT",
    ],
    Cmd.updateFirmware: [
      "SUCCESS", "BAD_FILENAME_LEN", "BAD_EXTENSION_FILE", "FILE_NOT_FOUND",
      "PARTITION_UPDATE_NOT_FOUND", "FAIL_OPEN_FILE", "FAIL_ERASE_PARTITION",
      "FAIL_WRITE_FIRMWARE", "FAIL_ENABLE_BOOT_PARTITION", "BAD_FILE_FORMAT", "BAD_SHA256",
    ],
    Cmd.setDate: ["SUCCESS", "BAD_ARG_LEN"],
    Cmd.setWifi: ["SUCCESS", "BAD_CMD_LEN", "BAD_HIDDEN_VALUE", "BAD_SSID_LEN", "BAD_PASSWORD_LEN"],
    Cmd.setEnablingHours: ["SUCCESS", "BAD_CMD_LEN", "BAD_VALUE"],
    Cmd.searchFile: ["SUCCESS", "FILE_NOT_FOUND", "FAIL_OPEN"],
  ]

  public static func statusName(_ cmd: UInt8, _ code: UInt8?) -> String {
    guard let code else { return "UNKNOWN(nil)" }
    let list = statuses[cmd] ?? []
    return Int(code) < list.count ? list[Int(code)] : "UNKNOWN(\(code))"
  }

  public struct Frame: Equatable {
    public let cmd: UInt8
    public let payload: [UInt8]
  }

  public static func crc32MPEG2<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes {
      crc ^= UInt32(b) << 24
      for _ in 0..<8 {
        crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
      }
    }
    return crc
  }

  public static func encode(_ cmd: UInt8, _ payload: [UInt8] = []) throws -> [UInt8] {
    guard payload.count <= 250 else {
      throw MerlinError("payload too large for one frame (\(payload.count) bytes)")
    }
    let body = [cmd] + payload
    return [UInt8(payload.count + 5)] + body + le32(crc32MPEG2(body))
  }

  /// Incremental decoder mirroring the app's read loop: bytes are appended,
  /// complete frames are pulled with `nextFrame`, and raw (unframed) bytes can
  /// be pulled with `take` during file downloads.
  public final class Decoder {
    private var buf: [UInt8] = []
    private var head = 0
    private let logger: ((String) -> Void)?

    public init(logger: ((String) -> Void)? = nil) { self.logger = logger }

    public var count: Int { buf.count - head }

    public func append<S: Sequence>(_ data: S) where S.Element == UInt8 {
      if head > 0 && head > buf.count / 2 { // compact now and then
        buf.removeFirst(head)
        head = 0
      }
      buf.append(contentsOf: data)
    }

    public func take(_ max: Int) -> [UInt8] {
      let n = Swift.min(max, count)
      defer { head += n }
      return Array(buf[head..<head + n])
    }

    public func nextFrame() -> Frame? {
      while count > 0 {
        let len = Int(buf[head])
        if len < 5 { // resync, same as the app
          head += 1
          continue
        }
        guard count >= len + 1 else { return nil }
        let raw = Array(buf[head..<head + len + 1])
        head += len + 1
        let body = Array(raw[1..<len - 3])
        let expected = u32le(raw, len - 3)
        let actual = crc32MPEG2(body)
        if actual != expected {
          logger?(String(format: "bad CRC %08x != %08x, dropping frame", actual, expected))
          continue
        }
        return Frame(cmd: body[0], payload: Array(body.dropFirst()))
      }
      return nil
    }
  }
}

func le32(_ v: UInt32) -> [UInt8] {
  [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
}

func u32le(_ b: [UInt8], _ at: Int) -> UInt32 {
  guard at + 4 <= b.count else { return 0 }
  return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
}

func hex(_ bytes: some Sequence<UInt8>) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}
