import CryptoKit
import Foundation

/// How to reach the speaker, shared by every connection of a sync.
public struct SpeakerOptions {
  public var host: String
  public var port: Int
  public var logger: ((String) -> Void)?
  public var ackTimeout: Double
  public var cancel: CancelToken?

  public init(host: String = Speaker.defaultHost, port: Int = Speaker.defaultPort,
              logger: ((String) -> Void)? = nil, ackTimeout: Double = Speaker.ackTimeout, cancel: CancelToken? = nil) {
    self.host = host
    self.port = port
    self.logger = logger
    self.ackTimeout = ackTimeout
    self.cancel = cancel
  }
}

public struct SpeakerInfo {
  public let firmwareVersion: String
  public let macAddress: String
  public let batteryLevel: Int
  public let charging: Bool
  public let totalSize: UInt32
  public let availableSpace: UInt32
  public let date: Date?
}

public enum UploadResult { case uploaded, alreadyPresent }

/// Client for the speaker's TCP control/transfer protocol. The speaker exposes
/// it on its own Wi-Fi access point; join that network first.
public final class Speaker {
  typealias Cmd = WireProtocol.Cmd

  public static let defaultHost = "192.168.4.1"
  public static let defaultPort = 50_000
  static let chunkSize = 100 * 1024 // same chunking as the app when streaming files
  // Live speaker timings (logs): commands answer in ~5-400 ms, data streams at
  // ~800 KB/s. Limits are a comfortable margin above that, not the app's
  // open-ended waits, so a dead link is noticed (and recovered) quickly.
  public static let defaultTimeout = 5.0
  /// Max wait for the speaker to accept an upload / make progress on a write.
  public static let ackTimeout = 5.0
  /// Cap for waits on the speaker (except applying a playlist); longer
  /// outages are handled by retrying (see Sync.linkRetries).
  public static let maxTimeout = 15.0
  /// The speaker rebuilds its whole library when applying a playlist.
  public static let playlistTimeout = 120.0
  /// A verifying search reads and hashes the whole file (~1.6 MB/s measured):
  /// allow 1 s per MB on top of the usual command timeout.
  static let verifyBytesPerSecond = 1_000_000.0

  public let options: SpeakerOptions
  private var conn: TCPConnection?
  private lazy var decoder = WireProtocol.Decoder(logger: { [weak self] in self?.log($0) })

  public init(_ options: SpeakerOptions) { self.options = options }

  public static func open(_ options: SpeakerOptions) throws -> Speaker {
    let s = Speaker(options)
    try s.connect()
    return s
  }

  @discardableResult
  public func connect(timeout: Double = 3) throws -> Speaker {
    do {
      conn = try TCPConnection.connect(host: options.host, port: options.port, timeout: timeout, cancel: options.cancel)
      log("connected to \(options.host):\(options.port)")
      return self
    } catch let e as SpeakerError {
      log("connect to \(options.host):\(options.port) failed: \(e.message)")
      throw SpeakerError.link("TCP connect failed to \(options.host):\(options.port) — \(e.message)")
    } catch let e as SocketFailure {
      throw SpeakerError.link("TCP connect failed to \(options.host):\(options.port) — \(e.message)")
    }
  }

  public func close() {
    conn?.close()
    conn = nil
  }

  public var isConnected: Bool { conn?.isOpen ?? false }

  // MARK: Simple queries

  public func ping(timeout: Double = 2) throws {
    _ = try request(Cmd.ping, timeout: timeout)
  }

  public func availableSpace() throws -> UInt32 { u32le(try request(Cmd.availableSpace).payload, 0) }
  public func totalSize() throws -> UInt32 { u32le(try request(Cmd.totalSize).payload, 0) }

  public func firmwareVersion() throws -> String {
    let p = try request(Cmd.firmwareVersion).payload
    guard p.count >= 4 else { return "?" }
    return "\(p[0]).\(p[1]).\(UInt16(p[2]) | UInt16(p[3]) << 8)"
  }

  public func batteryState() throws -> (level: Int, charging: Bool) {
    let p = try request(Cmd.batteryState).payload
    return (Int(p.first ?? 0), p.count > 1 && p[1] != 0)
  }

  /// The app formats the MAC as six *decimal* octets joined by ":" (and
  /// reports it to the backend that way), so keep that format.
  public func macAddress() throws -> String {
    try request(Cmd.macAddress).payload.prefix(6).map(String.init).joined(separator: ":")
  }

  /// The speaker clock holds local wall-clock time encoded as if it were UTC.
  public func date() throws -> Date? {
    let secs = u32le(try request(Cmd.getDate).payload, 0)
    return secs == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(secs))
  }

  public func info() throws -> SpeakerInfo {
    let battery = try batteryState()
    return SpeakerInfo(firmwareVersion: try firmwareVersion(), macAddress: try macAddress(),
                       batteryLevel: battery.level, charging: battery.charging,
                       totalSize: try totalSize(), availableSpace: try availableSpace(), date: try date())
  }

  // MARK: Settings

  public func setDate(_ date: Date = Date()) throws {
    let local = Int(date.timeIntervalSince1970) + TimeZone.current.secondsFromGMT(for: date)
    try checkStatus(Cmd.setDate, request(Cmd.setDate, le32(UInt32(truncatingIfNeeded: local))))
  }

  /// Two daily windows during which the speaker may be used, each as
  /// ((start h, start m), (end h, end m)). The app disables a window by
  /// sending 10:00-10:00.
  public typealias Window = ((Int, Int), (Int, Int))

  public func setEnablingHours(_ w1: Window, _ w2: Window) throws {
    let bytes = [w1.0.0, w1.0.1, w1.1.0, w1.1.1, w2.0.0, w2.0.1, w2.1.0, w2.1.1].map { UInt8(clamping: $0) }
    try checkStatus(Cmd.setEnablingHours, request(Cmd.setEnablingHours, bytes))
  }

  public func setWifi(ssid: String, password: String, hidden: Bool = false) throws {
    let s = Array(ssid.utf8), p = Array(password.utf8)
    let payload = [hidden ? 1 : 0, UInt8(clamping: s.count), UInt8(clamping: p.count)] + s + p
    try checkStatus(Cmd.setWifi, request(Cmd.setWifi, payload))
  }

  public func endSynchronization() throws { _ = try request(Cmd.endSynchronization) }
  public func reset() throws { _ = try request(Cmd.reset, timeout: 5) }

  /// Asks the speaker to (re)build its library from an uploaded playlist JSON.
  public func updatePlaylist(_ filename: String, timeout: Double = Speaker.playlistTimeout) throws {
    try checkStatus(Cmd.updatePlaylist, request(Cmd.updatePlaylist, Array(filename.utf8), timeout: timeout))
  }

  public func updateFirmware(_ filename: String, timeout: Double = 15) throws {
    try checkStatus(Cmd.updateFirmware, request(Cmd.updateFirmware, Array(filename.utf8), timeout: timeout))
  }

  // MARK: Files

  public struct SearchResult {
    public let found: Bool
    public let size: UInt32?
    public let sha256: String?
    public let raw: String
  }

  /// With verify, the speaker hashes the file so it can be compared with a local copy.
  public func searchFile(_ filename: String, verify: Bool = true, size: Int = 0, timeout: Double? = nil) throws -> SearchResult {
    let timeout = timeout ?? options.ackTimeout + (verify ? Double(size) / Self.verifyBytesPerSecond : 0)
    let p = try request(Cmd.searchFile, [verify ? 1 : 0] + Array(filename.utf8), timeout: timeout).payload
    switch p.first {
    case 0:
      // Firmware 2.1.16 replies [status][nameLen][name][size u32 LE][sha256],
      // like getFile. The app's code (1.20.5) reads the hash right after the
      // name; accept that layout too in case older firmware sends it.
      let nameLen = p.count > 1 ? Int(p[1]) : 0
      let rest = p.count > 2 + nameLen ? Array(p[(2 + nameLen)...]) : []
      var fileSize: UInt32?
      var sha: [UInt8]?
      if rest.count == 36 { fileSize = u32le(rest, 0); sha = Array(rest[4...]) } else if rest.count == 32 { sha = rest }
      return SearchResult(found: true, size: fileSize, sha256: sha.flatMap { verify ? hex($0) : nil }, raw: hex(p))
    case 1:
      return SearchResult(found: false, size: nil, sha256: nil, raw: hex(p))
    default:
      throw SpeakerError.refused("searchFile: \(WireProtocol.statusName(Cmd.searchFile, p.first))")
    }
  }

  /// Uploads data under filename (skipped by the speaker when it already
  /// holds the same name and SHA-256). `timeout` bounds the final
  /// acknowledgement once all bytes are sent (the speaker verifies the hash).
  public func upload(_ filename: String, _ data: Data, timeout: Double? = nil,
                     progress: ((Int, Int) -> Void)? = nil) throws -> UploadResult {
    let name = Array(filename.utf8)
    guard name.count <= 200 else { throw MerlinError("filename too long") }
    let header = [UInt8(name.count)] + name + le32(UInt32(data.count)) + Array(SHA256.hash(data: data))
    var status = try request(Cmd.uploadFile, header, timeout: options.ackTimeout).payload.first
    if status == 1 { return .alreadyPresent }
    guard status == 0 else {
      throw SpeakerError.refused("upload \(filename): \(WireProtocol.statusName(Cmd.uploadFile, status))")
    }

    let bytes = [UInt8](data)
    var sent = 0
    do {
      while sent < bytes.count {
        let end = min(sent + Self.chunkSize, bytes.count)
        try writeAll(bytes[sent..<end], what: "data of \(filename)")
        sent = end
        progress?(sent, bytes.count)
      }
    } catch let e as SocketFailure {
      log("!! socket error while sending \(filename): \(e.message)")
      throw SpeakerError.link("upload \(filename): \(e.message)")
    }
    log("   streamed \(filename): \(bytes.count) B")
    // +1 s/MB (observed: 0.14 s for 4.5 MB)
    let ack = timeout ?? min(options.ackTimeout + Double(bytes.count / 1_000_000), Self.maxTimeout)
    status = try waitFor(Cmd.uploadFile, timeout: ack).payload.first
    guard status == 1 else {
      throw SpeakerError.refused("upload \(filename): \(WireProtocol.statusName(Cmd.uploadFile, status))")
    }
    return .uploaded
  }

  /// Uploads unless an identical file is already there (what the app does).
  public func syncFile(_ filename: String, _ data: Data, progress: ((Int, Int) -> Void)? = nil) throws -> UploadResult {
    let remote = try searchFile(filename, verify: true, size: data.count)
    let local = hex(SHA256.hash(data: data))
    let sameSize = remote.size == nil || Int(remote.size!) == data.count
    if remote.found && remote.sha256 == local && sameSize { return .alreadyPresent }
    if remote.found {
      log("   \(filename) differs on the speaker: speaker sha=\(remote.sha256 ?? "none") size=\(remote.size.map(String.init) ?? "?"), "
        + "local sha=\(local) size=\(data.count) (raw reply \(remote.raw))")
    }
    return try upload(filename, data, progress: progress)
  }

  /// Downloads a file from the speaker. Some names are virtual and produce
  /// data on demand (e.g. get_listening.cmd returns listening statistics).
  public func getFile(_ filename: String, timeout: Double = 10) throws -> Data {
    let p = try request(Cmd.getFile, Array(filename.utf8), timeout: timeout).payload
    guard p.first == 0, p.count >= 2 else {
      throw SpeakerError.refused("getFile \(filename) failed: status=\(p.first.map(String.init) ?? "?")")
    }
    let nameLen = Int(p[1])
    let size = Int(u32le(p, 2 + nameLen))
    let sha = Array(p.dropFirst(6 + nameLen).prefix(32))
    let data = Data(try readRaw(size, timeout: timeout))
    guard Array(SHA256.hash(data: data)) == sha else { throw SpeakerError.refused("getFile \(filename): SHA-256 mismatch") }
    return data
  }

  // MARK: Transport

  public func request(_ cmd: UInt8, _ payload: [UInt8] = [], timeout: Double = Speaker.defaultTimeout) throws -> WireProtocol.Frame {
    guard isConnected else { throw SpeakerError.link("not connected") }
    log("-> \(Cmd.name(cmd)) \(describeRequest(cmd, payload))")
    do {
      try writeAll(try WireProtocol.encode(cmd, payload)[...], what: Cmd.name(cmd))
      return try waitFor(cmd, timeout: timeout)
    } catch let e as SocketFailure {
      log("!! socket error during \(Cmd.name(cmd)): \(e.message)")
      throw SpeakerError.link(e.message)
    }
  }

  private func waitFor(_ cmd: UInt8, timeout: Double) throws -> WireProtocol.Frame {
    let started = monotonic()
    let deadline = started + timeout
    while true {
      while let frame = decoder.nextFrame() {
        log("<- \(Cmd.name(frame.cmd)) \(describeResponse(frame)) [\(Int(((monotonic() - started) * 1000).rounded()))ms]")
        if frame.cmd == cmd { return frame }
        if frame.cmd == Cmd.unknown {
          throw SpeakerError.refused("speaker rejected cmd \(cmd) (CMD_UNKNOWN, status=\(frame.payload.first.map(String.init) ?? "nil"))")
        }
        log("ignoring unexpected cmd \(frame.cmd)")
      }
      try fill(deadline: deadline, what: "cmd \(cmd)")
    }
  }

  private func readRaw(_ size: Int, timeout: Double) throws -> [UInt8] {
    let deadline = monotonic() + timeout
    var out: [UInt8] = []
    out.reserveCapacity(size)
    while out.count < size {
      out += decoder.take(size - out.count)
      if out.count < size { try fill(deadline: deadline, what: "file data") }
    }
    return out
  }

  private func fill(deadline: Double, what: String) throws {
    guard let conn else { throw SpeakerError.link("not connected") }
    let left = deadline - monotonic()
    if left <= 0 { try timedOut(what) }
    do {
      guard try conn.wait(events: Int16(POLLIN), timeout: left) else { try timedOut(what) }
      switch try conn.readAvailable() {
      case .data(let bytes): decoder.append(bytes)
      case .wouldBlock: return
      case .closed:
        log("!! socket closed by speaker while waiting for \(what)")
        throw SpeakerError.link("socket closed by speaker")
      }
    } catch let e as SocketFailure {
      log("!! socket error while waiting for \(what): \(e.message)")
      throw SpeakerError.link(e.message)
    }
  }

  private func timedOut(_ what: String) throws -> Never {
    log("!! timed out waiting for \(what)")
    throw SpeakerError.timeout("timed out waiting for \(what)")
  }

  /// Like a blocking write but bounded: if the speaker stops reading, a plain
  /// write would hang forever once the TCP window is full.
  private func writeAll(_ data: ArraySlice<UInt8>, what: String) throws {
    guard let conn else { throw SpeakerError.link("not connected") }
    var rest = data
    var deadline = monotonic() + options.ackTimeout
    while !rest.isEmpty {
      let n = try conn.writeSome(rest)
      if n > 0 {
        rest = rest.dropFirst(n)
        deadline = monotonic() + options.ackTimeout // a stall, not the whole transfer, is bounded
        continue
      }
      let left = deadline - monotonic()
      let writable = left > 0 ? try conn.wait(events: Int16(POLLOUT), timeout: left) : false
      if !writable { try timedOut("the speaker to accept \(what)") }
    }
  }

  /// Human-readable request summary for the speaker log; Wi-Fi credentials
  /// (cmd 16) are never written.
  private func describeRequest(_ cmd: UInt8, _ p: [UInt8]) -> String {
    func text(_ b: ArraySlice<UInt8>) -> String { String(decoding: b, as: UTF8.self) }
    switch cmd {
    case Cmd.uploadFile:
      guard let n = p.first.map(Int.init), p.count >= 5 + n else { return "\(p.count) B" }
      return "\(text(p[1..<1 + n])) (\(u32le(p, 1 + n)) B)"
    case Cmd.searchFile: return "\(text(p.dropFirst())) verify=\(p.first == 1)"
    case Cmd.updatePlaylist, Cmd.updateFirmware, Cmd.getFile: return text(p[...])
    case Cmd.setWifi: return "[REDACTED]"
    case Cmd.setDate:
      let f = DateFormatter()
      f.timeZone = TimeZone(identifier: "UTC")
      f.dateFormat = "yyyy-MM-dd HH:mm:ss"
      return "\(f.string(from: Date(timeIntervalSince1970: TimeInterval(u32le(p, 0))))) (local, sent as UTC)"
    case Cmd.setEnablingHours:
      guard p.count == 8 else { return "\(p.count) B" }
      let t = stride(from: 0, to: 8, by: 2).map { String(format: "%02d:%02d", p[$0], p[$0 + 1]) }
      return "\(t[0])-\(t[1]), \(t[2])-\(t[3])"
    default: return p.isEmpty ? "" : "\(p.count) B"
    }
  }

  private func describeResponse(_ frame: WireProtocol.Frame) -> String {
    let status = frame.payload.first
    if WireProtocol.statuses[frame.cmd] != nil, status != nil { return WireProtocol.statusName(frame.cmd, status) }
    if frame.cmd == Cmd.unknown { return "CMD_UNKNOWN status=\(status.map(String.init) ?? "nil")" }
    return "\(frame.payload.count) B"
  }

  private func checkStatus(_ cmd: UInt8, _ frame: WireProtocol.Frame) throws {
    guard frame.payload.first == 0 else {
      throw SpeakerError.refused("\(WireProtocol.statusName(cmd, frame.payload.first)) (cmd \(cmd))")
    }
  }

  private func log(_ msg: String) { options.logger?(msg) }
}
