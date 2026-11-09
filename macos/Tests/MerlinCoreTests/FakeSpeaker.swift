import CryptoKit
import Darwin
import Foundation
@testable import MerlinCore

/// Minimal in-process emulation of the speaker firmware (a real TCP server on
/// 127.0.0.1), with the fault injection the recovery tests need.
final class FakeSpeaker: @unchecked Sendable {
  typealias Cmd = WireProtocol.Cmd

  private let lock = NSLock()
  private var listenFD: Int32 = -1
  private(set) var port = 0

  private var _files: [String: [UInt8]] = [:]
  private var _commands: [UInt8] = []
  private var _playlistUpdates: [String] = []
  private var _connections = 0
  private var _hours: [UInt8]?
  private var _wifi: (String, String)?
  private var _date: UInt32?
  private var uploadHeaders = 0
  private var pings = 0
  private var resetsPending = 0

  /// Upload-header numbers (1-based, across connections) never answered.
  var silentUploads: Set<Int> = []
  /// Status code returned to every upload header instead of 0.
  var uploadRefusal: UInt8?
  /// Ping numbers (1-based) left unanswered (speaker not ready after reboot).
  var silentPings: Set<Int> = []
  /// After a silent upload, this many new connections are accepted then reset.
  var resetAfterDrop = 0

  var files: [String: [UInt8]] { lock.withLock { _files } }
  var commands: [UInt8] { lock.withLock { _commands } }
  var playlistUpdates: [String] { lock.withLock { _playlistUpdates } }
  var connections: Int { lock.withLock { _connections } }
  var hours: [UInt8]? { lock.withLock { _hours } }
  var wifi: (String, String)? { lock.withLock { _wifi } }
  var date: UInt32? { lock.withLock { _date } }

  func file(_ name: String) -> String? { files[name].map { String(decoding: $0, as: UTF8.self) } }

  init() {
    listenFD = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(listenFD, 16)
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listenFD, $0, &len) } }
    port = Int(UInt16(bigEndian: addr.sin_port))
    let t = Thread { [self] in serve() }
    t.start()
  }

  func stop() {
    let fd = lock.withLock { () -> Int32 in let f = listenFD; listenFD = -1; return f }
    if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
  }

  private func serve() {
    while true {
      let fd = lock.withLock { listenFD }
      guard fd >= 0 else { return }
      let client = accept(fd, nil, nil)
      guard client >= 0 else { return }
      var one: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      let reset: Bool = lock.withLock {
        _connections += 1
        if resetsPending > 0 { resetsPending -= 1; return true }
        return false
      }
      if reset {
        var l = linger(l_onoff: 1, l_linger: 0) // close => RST
        setsockopt(client, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
        close(client)
        continue
      }
      handle(client)
      close(client)
    }
  }

  private struct PendingUpload { let name: String; let size: Int; let sha: [UInt8]; var data: [UInt8] }

  private func handle(_ sock: Int32) {
    let decoder = WireProtocol.Decoder()
    var pending: PendingUpload?
    var buf = [UInt8](repeating: 0, count: 65_536)
    while true {
      let n = read(sock, &buf, buf.count)
      if n <= 0 { return } // client gone
      decoder.append(buf[0..<n])
      while true {
        if var p = pending {
          p.data += decoder.take(p.size - p.data.count)
          pending = p
          guard p.data.count == p.size else { break }
          let ok = Array(SHA256.hash(data: p.data)) == p.sha
          if ok { lock.withLock { _files[p.name] = p.data } }
          reply(sock, Cmd.uploadFile, [ok ? 1 : 4])
          pending = nil
          continue
        }
        guard let frame = decoder.nextFrame() else { break }
        lock.withLock { _commands.append(frame.cmd) }
        pending = dispatch(sock, frame)
      }
    }
  }

  private func dispatch(_ sock: Int32, _ frame: WireProtocol.Frame) -> PendingUpload? {
    let p = frame.payload
    switch frame.cmd {
    case Cmd.ping:
      let n = lock.withLock { pings += 1; return pings }
      if !silentPings.contains(n) { reply(sock, frame.cmd, []) }
    case Cmd.endSynchronization, Cmd.reset: reply(sock, frame.cmd, [])
    case Cmd.availableSpace: reply(sock, frame.cmd, le32(1_000_000))
    case Cmd.totalSize: reply(sock, frame.cmd, le32(8_000_000))
    case Cmd.firmwareVersion: reply(sock, frame.cmd, [1, 4, 27, 0])
    case Cmd.batteryState: reply(sock, frame.cmd, [87, 1])
    case Cmd.macAddress: reply(sock, frame.cmd, [0xAA, 0xBB, 0xCC, 1, 2, 3])
    case Cmd.getDate: reply(sock, frame.cmd, le32(date ?? 0))
    case Cmd.setDate:
      lock.withLock { _date = u32le(p, 0) }
      reply(sock, frame.cmd, [0])
    case Cmd.setEnablingHours:
      lock.withLock { _hours = p }
      reply(sock, frame.cmd, [0])
    case Cmd.setWifi:
      let s = Int(p[1]), w = Int(p[2])
      lock.withLock { _wifi = (String(decoding: p[3..<3 + s], as: UTF8.self), String(decoding: p[3 + s..<3 + s + w], as: UTF8.self)) }
      reply(sock, frame.cmd, [0])
    case Cmd.updatePlaylist:
      let name = String(decoding: p, as: UTF8.self)
      let exists = lock.withLock { _playlistUpdates.append(name); return _files[name] != nil }
      reply(sock, frame.cmd, [exists ? 0 : 3])
    case Cmd.searchFile:
      let name = String(decoding: p.dropFirst(), as: UTF8.self)
      if let content = files[name] {
        let nb = Array(name.utf8)
        reply(sock, frame.cmd, [0, UInt8(nb.count)] + nb + le32(UInt32(content.count)) + Array(SHA256.hash(data: content)))
      } else {
        reply(sock, frame.cmd, [1])
      }
    case Cmd.uploadFile:
      let n = Int(p[0])
      let name = String(decoding: p[1..<1 + n], as: UTF8.self)
      let size = Int(u32le(p, 1 + n))
      let sha = Array(p[(5 + n)...])
      let header = lock.withLock { uploadHeaders += 1; return uploadHeaders }
      if silentUploads.contains(header) { // never answer
        lock.withLock { resetsPending = resetAfterDrop }
        return nil
      }
      if let refusal = uploadRefusal {
        reply(sock, frame.cmd, [refusal])
        return nil
      }
      if let existing = files[name], Array(SHA256.hash(data: existing)) == sha {
        reply(sock, frame.cmd, [1])
        return nil
      }
      reply(sock, frame.cmd, [0])
      return PendingUpload(name: name, size: size, sha: sha, data: [])
    default:
      reply(sock, Cmd.unknown, [0])
    }
    return nil
  }

  private func reply(_ sock: Int32, _ cmd: UInt8, _ payload: [UInt8]) {
    let frame = try! WireProtocol.encode(cmd, payload)
    _ = frame.withUnsafeBytes { write(sock, $0.baseAddress, $0.count) }
  }
}
