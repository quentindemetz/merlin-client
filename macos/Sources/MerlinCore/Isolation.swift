import Darwin
import Foundation

/// What a sync needs from the traffic filter (tests use a stub).
public protocol TrafficFilter: AnyObject {
  var isActive: Bool { get }
  func enable() throws
  func disable() throws
}

/// Starts the root helper. Production: the standard macOS admin password
/// dialog (AppleScript `with administrator privileges`). Tests: a plain shell.
public protocol PrivilegedLauncher {
  /// Runs `/bin/sh -c script merlin-isolation args...` in the background,
  /// detached from any terminal, and returns once it's launched.
  func launch(script: String, args: [String]) throws
}

/// Keeps the rest of this Mac's traffic away from the speaker during a
/// transfer — the root cause of the speaker crashing on macOS.
///
/// On Android the app binds itself to the speaker network, so the speaker
/// only ever sees one TCP connection. On macOS, joining the speaker's Wi-Fi
/// makes it the gateway and DNS server for the whole machine, and the burst of
/// reconnecting apps / DNS / captive portal probes makes the speaker reboot.
///
/// We install a pf rule that only lets our TCP session and DHCP leave the Mac
/// from the speaker's subnet, in the com.apple/merlin anchor (evaluated by the
/// stock /etc/pf.conf).
///
/// Admin rights: one password prompt starts a small root helper that only
/// knows "on", "off" and "quit". It talks to us over two FIFOs in a private
/// directory and lives as long as the app: when the app goes away, its end of
/// the command FIFO closes and the helper exits.
public final class Isolation: TrafficFilter, @unchecked Sendable {
  public static let anchor = "com.apple/merlin"
  static let replyTimeout = 15.0

  /// $1 = rules, $2 = pfctl path, $3 = command FIFO, $4 = reply FIFO.
  static let helperScript = #"""
    rules=$1; pfctl=$2
    exec 3<"$3" 4>"$4"
    echo __READY__ >&4
    while IFS= read -r cmd <&3; do
      case "$cmd" in
        on)
          if printf '%s' "$rules" | "$pfctl" -a com.apple/merlin -f - >&4 2>&1 && "$pfctl" -E >&4 2>&1
          then echo __OK__ >&4; else echo __FAIL__ >&4; fi ;;
        off*)
          tok=${cmd#off}; tok=${tok# }
          case "$tok" in *[!0-9]*) tok= ;; esac
          if "$pfctl" -a com.apple/merlin -F all >&4 2>&1
          then [ -z "$tok" ] || "$pfctl" -X "$tok" >&4 2>&1; echo __OK__ >&4; else echo __FAIL__ >&4; fi ;;
        quit) exit 0 ;;
        *) echo "unknown command" >&4; echo __FAIL__ >&4 ;;
      esac
    done
    """#

  private let statePath: URL
  private var iface: String?
  private let speakerIP: String
  private let port: Int
  private let subnet: String
  private let pfctl: String
  private let launcher: PrivilegedLauncher
  private let lock = NSRecursiveLock()

  /// Where status lines go (each sync points it at its own log).
  public var out: ((String) -> Void)?

  private var token: String?
  private var pipeDir: URL?
  private var cmdFD: Int32 = -1
  private var replyFD: Int32 = -1
  private var replyBuffer: [UInt8] = []

  public init(statePath: URL, interface: String? = nil, speakerIP: String = Speaker.defaultHost, port: Int = Speaker.defaultPort,
              subnet: String = "192.168.4.0/24", pfctl: String = "/sbin/pfctl",
              launcher: PrivilegedLauncher = AdminPromptLauncher(), out: ((String) -> Void)? = nil) {
    self.statePath = statePath
    iface = interface
    self.speakerIP = speakerIP
    self.port = port
    self.subnet = subnet
    self.pfctl = pfctl
    self.launcher = launcher
    self.out = out
  }

  deinit { shutdownHelper() }

  var interface: String {
    if let iface { return iface }
    let name = MacNetwork().interfaceName
    iface = name
    return name
  }

  public var rules: String {
    """
    pass out quick on \(interface) proto tcp from \(subnet) to \(speakerIP) port \(port)
    pass out quick on \(interface) proto udp from any port 68 to any port 67
    block out quick on \(interface) from \(subnet) to any

    """
  }

  public var isActive: Bool { lock.withLock { token != nil } }
  public var hasLeftover: Bool { FileManager.default.fileExists(atPath: statePath.path) }
  public var isAuthorized: Bool { lock.withLock { cmdFD >= 0 } }

  /// Asks for the admin password (once per app session) and starts the helper.
  public func authorize() throws {
    try lock.withLock {
      if cmdFD >= 0 { return }
      let fm = FileManager.default
      let dir = fm.temporaryDirectory.appendingPathComponent("merlin-isolation-\(UUID().uuidString)")
      try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let cmdPath = dir.appendingPathComponent("cmd").path
      let replyPath = dir.appendingPathComponent("reply").path
      guard mkfifo(cmdPath, 0o600) == 0, mkfifo(replyPath, 0o600) == 0 else {
        try? fm.removeItem(at: dir)
        throw MerlinError("traffic filter: can't create pipes (\(errnoMessage()))")
      }
      // Read+write opens never block; the helper sees EOF on the command
      // pipe when we exit (it's the only reader, we're the only writer).
      cmdFD = open(cmdPath, O_RDWR)
      replyFD = open(replyPath, O_RDWR | O_NONBLOCK)
      pipeDir = dir
      do {
        try launcher.launch(script: Self.helperScript, args: [rules, pfctl, cmdPath, replyPath])
        let said = try readReply(until: "__READY__", timeout: 20)
        _ = said
      } catch {
        shutdownHelper()
        if error is CancellationError { throw MerlinError("admin rights are needed to isolate the speaker (cancelled)") }
        throw MerlinError("admin rights are needed to isolate the speaker (\(error.userMessage))")
      }
    }
  }

  public func enable() throws {
    try lock.withLock {
      try releaseLeftover()
      let output = try call("on")
      if let r = output.range(of: #"Token\s*:\s*(\d+)"#, options: .regularExpression) {
        token = output[r].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
      } else {
        token = ""
      }
      try? FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
      let state: JSONObject = ["token": token.flatMap { $0.isEmpty ? nil : $0 } ?? NSNull(), "interface": interface]
      try? JSON.data(state).write(to: statePath)
      out?("Traffic filter on: only the transfer can reach the speaker.")
    }
  }

  /// Turns the filter off; the helper stays up for the next sync.
  public func disable() throws {
    try lock.withLock {
      _ = try call("off \(token ?? "")")
      token = nil
      try? FileManager.default.removeItem(at: statePath)
      out?("Traffic filter off.")
    }
  }

  /// A previous run that died left rules / pf enabled: clean them up.
  public func releaseLeftover() throws {
    try lock.withLock {
      guard hasLeftover else { return }
      let state = (try? Data(contentsOf: statePath)).flatMap { try? JSON.parse($0) as? JSONObject } ?? [:]
      token = state.id("token") ?? ""
      try disable()
    }
  }

  public func shutdownHelper() {
    lock.withLock {
      if cmdFD >= 0 {
        _ = "quit\n".withCString { write(cmdFD, $0, strlen($0)) }
        Thread.sleep(forTimeInterval: 0.1) // let the helper read it before we close
        close(cmdFD)
      }
      if replyFD >= 0 { close(replyFD) }
      cmdFD = -1
      replyFD = -1
      replyBuffer = []
      if let dir = pipeDir { try? FileManager.default.removeItem(at: dir) }
      pipeDir = nil
    }
  }

  /// Sends one request to the root helper; returns its output.
  private func call(_ cmd: String) throws -> String {
    guard cmdFD >= 0 else { throw MerlinError("not authorized: the traffic filter needs admin rights first") }
    let line = Array((cmd + "\n").utf8)
    guard line.withUnsafeBytes({ write(cmdFD, $0.baseAddress, $0.count) }) == line.count else {
      throw MerlinError("traffic filter helper: \(errnoMessage())")
    }
    do {
      return try readReply(until: "__OK__", timeout: Self.replyTimeout)
    } catch let e as HelperFailed {
      throw MerlinError("pfctl \(cmd.split(separator: " ").first ?? "") failed: \(e.output.split(separator: "\n").last ?? "")")
    }
  }

  struct HelperFailed: Error { let output: String }

  /// Reads lines until `marker`; throws HelperFailed on __FAIL__.
  private func readReply(until marker: String, timeout: Double) throws -> String {
    var output = ""
    let deadline = monotonic() + timeout
    while true {
      while let nl = replyBuffer.firstIndex(of: 0x0A) {
        let line = String(decoding: replyBuffer[..<nl], as: UTF8.self)
        replyBuffer.removeFirst(nl + 1)
        if line.hasPrefix(marker) { return output }
        if line.hasPrefix("__FAIL__") { throw HelperFailed(output: output) }
        output += line + "\n"
      }
      let left = deadline - monotonic()
      guard left > 0 else { throw MerlinError("traffic filter helper did not answer") }
      var pfd = pollfd(fd: replyFD, events: Int16(POLLIN), revents: 0)
      if poll(&pfd, 1, Int32(min(left, 0.2) * 1000) + 1) > 0 {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(replyFD, &buf, buf.count)
        if n > 0 { replyBuffer += buf[0..<n] }
      }
    }
  }
}

/// The macOS admin password dialog, via AppleScript's
/// `do shell script ... with administrator privileges`.
public struct AdminPromptLauncher: PrivilegedLauncher {
  public init() {}

  static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  static func appleScriptString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  public func launch(script: String, args: [String]) throws {
    // Backgrounded with every stream redirected, so `do shell script` returns at once.
    let command = (["/bin/sh", "-c", script, "merlin-isolation"] + args).map(Self.shellQuote).joined(separator: " ")
      + " </dev/null >/dev/null 2>&1 &"
    let prompt = "Merlin needs your permission to keep this Mac's other network traffic away from the speaker during transfers."
    let source = "do shell script \(Self.appleScriptString(command)) with prompt \(Self.appleScriptString(prompt)) with administrator privileges"
    let out = try Shell.run("/usr/bin/osascript", ["-e", source])
    if out.status != 0 {
      if out.text.contains("-128") { throw CancellationError() }
      throw MerlinError(out.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}
