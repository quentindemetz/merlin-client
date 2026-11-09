import Darwin
import Foundation

/// A plain TCP client socket with bounded, cancellable waits (non-blocking fd + poll).
final class TCPConnection {
  private(set) var fd: Int32
  private let cancel: CancelToken?

  enum Read { case data([UInt8]), wouldBlock, closed }

  private init(fd: Int32, cancel: CancelToken?) {
    self.fd = fd
    self.cancel = cancel
  }

  deinit { close() }

  var isOpen: Bool { fd >= 0 }

  static func connect(host: String, port: Int, timeout: Double, cancel: CancelToken?) throws -> TCPConnection {
    var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                         ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, String(port), &hints, &res)
    guard rc == 0, let info = res else {
      throw SpeakerError.link("can't resolve \(host): \(String(cString: gai_strerror(rc)))")
    }
    defer { freeaddrinfo(res) }

    let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { throw SpeakerError.link(errnoMessage()) }
    let conn = TCPConnection(fd: fd, cancel: cancel)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) // EPIPE, not a crash
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 {
      guard errno == EINPROGRESS else { throw SpeakerError.link(errnoMessage()) }
      guard try conn.wait(events: Int16(POLLOUT), timeout: timeout) else {
        throw SpeakerError.link("connect timed out after \(Int(timeout)) s")
      }
      var err: Int32 = 0
      var len = socklen_t(MemoryLayout<Int32>.size)
      getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
      if err != 0 { throw SpeakerError.link(String(cString: strerror(err))) }
    }
    return conn
  }

  func close() {
    if fd >= 0 { Darwin.close(fd) }
    fd = -1
  }

  /// Waits until the socket is readable/writable; false on timeout. Wakes up
  /// every 100 ms to honour cancellation.
  func wait(events: Int16, timeout: Double) throws -> Bool {
    let deadline = monotonic() + timeout
    while true {
      try cancel.check()
      let left = deadline - monotonic()
      if left <= 0 { return false }
      var pfd = pollfd(fd: fd, events: events, revents: 0)
      let rc = poll(&pfd, 1, Int32(min(left, 0.1) * 1000) + 1)
      if rc > 0 { return true }
      if rc < 0 && errno != EINTR { throw SocketFailure(errno: errno) }
    }
  }

  func readAvailable(max: Int = 64 * 1024) throws -> Read {
    var buf = [UInt8](repeating: 0, count: max)
    let n = Darwin.read(fd, &buf, max)
    if n > 0 { return .data(Array(buf[0..<n])) }
    if n == 0 { return .closed }
    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return .wouldBlock }
    throw SocketFailure(errno: errno)
  }

  /// Bytes written, or 0 when the send buffer is full.
  func writeSome(_ bytes: ArraySlice<UInt8>) throws -> Int {
    let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    if n >= 0 { return n }
    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return 0 }
    throw SocketFailure(errno: errno)
  }
}

/// A failing socket call (connection reset, broken pipe...).
struct SocketFailure: Error {
  let errno: Int32

  var message: String {
    switch errno {
    case ECONNRESET: return "the speaker reset the connection"
    case EPIPE: return "the speaker closed the connection"
    default: return "socket error: \(String(cString: strerror(errno)))"
    }
  }
}

func errnoMessage() -> String { String(cString: strerror(errno)) }
