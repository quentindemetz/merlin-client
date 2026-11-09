import CoreLocation
import CoreWLAN
import Darwin
import Foundation

/// The macOS operations Wifi needs, in one place (tests use a fake).
public protocol NetworkControl: AnyObject {
  func currentSSID() throws -> String?
  func visibleSSIDs() throws -> [String]
  func ip() -> String?
  func join(_ ssid: String, password: String?) throws
  func forget(_ ssid: String)
  func powerCycle() throws
}

/// This Mac's Wi-Fi. Since macOS 14 the current network name and scan results
/// are only available to apps granted Location Services: this app asks for it
/// itself (see LocationPermission), no separate helper needed.
public final class MacNetwork: NetworkControl, @unchecked Sendable {
  public init() {}

  private var wifi: CWInterface? { CWWiFiClient.shared().interface() }

  public var interfaceName: String { wifi?.interfaceName ?? "en0" }

  public func currentSSID() throws -> String? { wifi?.ssid() }

  public func visibleSSIDs() throws -> [String] {
    guard let wifi else { throw MerlinError("no Wi-Fi interface") }
    let networks = try wifi.scanForNetworks(withSSID: nil)
    return Array(Set(networks.compactMap(\.ssid))).sorted()
  }

  /// IPv4 address of the Wi-Fi interface.
  public func ip() -> String? { Self.ipv4(of: interfaceName) }

  static func ipv4(of interface: String) -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
    defer { freeifaddrs(addrs) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let a = p.pointee
      guard String(cString: a.ifa_name) == interface, let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        return String(cString: host)
      }
    }
    return nil
  }

  /// Joins a network; for a known network the password comes from the keychain.
  public func join(_ ssid: String, password: String?) throws {
    try Shell.runChecked("/usr/sbin/networksetup", ["-setairportnetwork", interfaceName, ssid] + (password.map { [$0] } ?? []))
  }

  /// So macOS doesn't auto-join the speaker's access point later.
  public func forget(_ ssid: String) {
    _ = try? Shell.run("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", interfaceName, ssid])
  }

  /// Makes macOS auto-join its preferred network (used when the previous
  /// network's name couldn't be read).
  public func powerCycle() throws {
    guard let wifi else { throw MerlinError("no Wi-Fi interface") }
    try wifi.setPower(false)
    Thread.sleep(forTimeInterval: 3)
    try wifi.setPower(true)
  }
}

/// Location Services for this app (needed to read Wi-Fi names). Must be used
/// from the main thread.
@MainActor
public final class LocationPermission: NSObject, CLLocationManagerDelegate {
  public enum Status: Equatable { case authorized, denied, undetermined }

  private let manager = CLLocationManager()
  private var waiters: [(Status) -> Void] = []
  public var onChange: ((Status) -> Void)?

  public override init() {
    super.init()
    manager.delegate = self
  }

  public var status: Status {
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorized: return .authorized
    case .denied, .restricted: return .denied
    default: return .undetermined
    }
  }

  /// Shows macOS's dialog the first time; resolves once the user decides.
  public func request() async -> Status {
    if status != .undetermined { return status }
    return await withCheckedContinuation { cont in
      waiters.append { cont.resume(returning: $0) }
      manager.requestWhenInUseAuthorization()
    }
  }

  nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    MainActor.assumeIsolated {
      let s = status
      onChange?(s)
      guard s != .undetermined else { return }
      let w = waiters
      waiters = []
      w.forEach { $0(s) }
    }
  }
}

/// Runs command-line tools.
public enum Shell {
  public struct Output {
    public let status: Int32
    public let text: String
  }

  @discardableResult
  public static func run(_ path: String, _ args: [String]) throws -> Output {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Output(status: p.terminationStatus, text: String(decoding: data, as: UTF8.self))
  }

  /// networksetup exits 0 even on failure but prints an error.
  @discardableResult
  public static func runChecked(_ path: String, _ args: [String]) throws -> String {
    let out = try run(path, args)
    let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if out.status != 0 || text.range(of: "error|could not|failed", options: [.regularExpression, .caseInsensitive]) != nil {
      throw MerlinError(text.isEmpty ? "\(path) failed" : text)
    }
    return out.text
  }

  /// A command-line tool, wherever Homebrew or the system put it (apps
  /// launched from the Finder don't get the shell's PATH).
  public static func find(_ name: String) -> String? {
    let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"] + env
    return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
