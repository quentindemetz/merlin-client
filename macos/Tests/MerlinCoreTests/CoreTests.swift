import CryptoKit
import ImageIO
import Foundation
import Testing
@testable import MerlinCore

// MARK: - Wire protocol + speaker

@Suite struct ProtocolTests {
  @Test func crcMatchesCRC32MPEG2CheckValue() {
    #expect(WireProtocol.crc32MPEG2(Array("123456789".utf8)) == 0x0376_E6E7)
  }

  @Test func encodeLayout() throws {
    let frame = try WireProtocol.encode(2)
    #expect(frame.count == 6)
    #expect(frame[0] == 5 && frame[1] == 2)
    #expect(u32le(frame, 2) == WireProtocol.crc32MPEG2([2]))
  }

  @Test func decoderHandlesSplitGarbageAndBadCRC() throws {
    var bad = try WireProtocol.encode(3, [9])
    bad[2] ^= 0xFF
    let good = try WireProtocol.encode(5, [1, 2, 3, 4])
    let d = WireProtocol.Decoder()
    let stream = [1, 2] + bad + good // junk bytes < 5 are skipped, bad CRC dropped
    d.append(stream.prefix(5))
    #expect(d.nextFrame() == nil)
    d.append(stream.dropFirst(5))
    #expect(d.nextFrame() == WireProtocol.Frame(cmd: 5, payload: [1, 2, 3, 4]))
    #expect(d.nextFrame() == nil)
  }

  @Test func statusNames() {
    #expect(WireProtocol.statusName(6, 18) == "MUSIC_NOT_FOUND")
    #expect(WireProtocol.statusName(6, 200) == "UNKNOWN(200)")
  }
}

@Suite(.serialized) final class SpeakerTests {
  let fake = FakeSpeaker()
  deinit { fake.stop() }

  func open() throws -> Speaker { try Speaker.open(SpeakerOptions(host: "127.0.0.1", port: fake.port)) }

  @Test func info() throws {
    let s = try open()
    defer { s.close() }
    let i = try s.info()
    #expect(i.firmwareVersion == "1.4.27")
    #expect(i.macAddress == "170:187:204:1:2:3")
    #expect(i.batteryLevel == 87 && i.charging)
    #expect(i.totalSize == 8_000_000 && i.availableSpace == 1_000_000)
    #expect(i.date == nil)
  }

  @Test func uploadLargeFileThenSkipIdentical() throws {
    let s = try open()
    defer { s.close() }
    let data = Data((0..<350_000).map { UInt8($0 % 251) })
    var progress: [Int] = []
    #expect(try s.syncFile("big.mp3", data) { sent, _ in progress.append(sent) } == .uploaded)
    #expect(fake.files["big.mp3"] == [UInt8](data))
    #expect(progress == [102_400, 204_800, 307_200, 350_000])
    #expect(try s.syncFile("big.mp3", data) == .alreadyPresent)
  }

  @Test func searchMissingAndSettings() throws {
    let s = try open()
    defer { s.close() }
    #expect(try !s.searchFile("nope.mp3").found)
    try s.setEnablingHours(((7, 30), (19, 0)), ((10, 0), (10, 0)))
    #expect(fake.hours == [7, 30, 19, 0, 10, 0, 10, 0])
    try s.setWifi(ssid: "Maison", password: "secret")
    #expect(fake.wifi?.0 == "Maison")
  }

  @Test func playlistUpdateErrorsAreNamed() throws {
    let s = try open()
    defer { s.close() }
    let error = #expect(throws: SpeakerError.self) { try s.updatePlaylist("missing.json") }
    #expect(error?.message.contains("FILE_NOT_FOUND") == true)
    #expect(error?.kind == .refused)
  }

  @Test func unknownCommandRaises() throws {
    let s = try open()
    defer { s.close() }
    let error = #expect(throws: SpeakerError.self) { try s.request(0x42) }
    #expect(error?.message.contains("CMD_UNKNOWN") == true)
  }
}

// MARK: - JSON

@Suite struct OrderedJSONTests {
  @Test func roundTripKeepsOrderAndLiterals() throws {
    let text = #"[{"uuid":"u1","title":"Contes \"é\" / ok","n":1.50,"child":[{"z":null,"a":true}]}]"#
    #expect(try OrderedJSON.parse(text).serialized == text)
  }

  @Test func unicodeEscapes() throws {
    #expect(try OrderedJSON.parse(#""é😀\n""#) == .string("é😀\n"))
  }
}

// MARK: - Redaction

@Suite struct RedactTests {
  @Test func nestedKeysInAnyCaseStyle() {
    let out = Redact.value(["access_token": "a", "refreshToken": "b", "speaker": ["speaker_name": "Lou", "id": 7]]) as! JSONObject
    #expect(out.str("access_token") == "[REDACTED]")
    #expect(out.str("refreshToken") == "[REDACTED]")
    #expect(out.obj("speaker")?.str("speaker_name") == "[REDACTED]")
    #expect(out.obj("speaker")?.int("id") == 7)
  }

  @Test func homeSSIDRedactedButSpeakerAPKept() {
    let out = Redact.value([["ssid": "Cohen", "password": "x"], ["ssid": "MERLIN_DKCRG8"]]) as! [JSONObject]
    #expect(out[0].str("ssid") == "[REDACTED]" && out[0].str("password") == "[REDACTED]")
    #expect(out[1].str("ssid") == "MERLIN_DKCRG8")
  }

  @Test func freeTextScrubbing() {
    #expect(Redact.scrub("user kid@example.com got Bearer abc.def and eyJhbGciOi.eyJzdWIiOi.sig")
      == "user [EMAIL] got Bearer [REDACTED] and [JWT]")
  }

  @Test func truncatedJSONStillRedactsKnownKeys() {
    let out = Redact.scrub(#"{"id":"s1","refresh_token":"abc","pendingPassword":"x"#)
    #expect(out.contains(#""id":"s1""#))
    #expect(!out.contains("abc"))
    #expect(out.contains(#""refresh_token":"[REDACTED]""#))
  }

  @Test func formAndURL() {
    let form = Redact.body(Data("grant_type=refresh_token&refresh_token=xyz&client_id=app".utf8),
                           contentType: "application/x-www-form-urlencoded") as! [String: Any]
    #expect(form["refresh_token"] as? String == "[REDACTED]")
    #expect(form["client_id"] as? String == "app")
    #expect(Redact.url("https://cdn/x.mp3?X-Amz-Signature=abc&w=1").contains("X-Amz-Signature=%5BREDACTED%5D&w=1")
      || Redact.url("https://cdn/x.mp3?X-Amz-Signature=abc&w=1").contains("X-Amz-Signature=[REDACTED]&w=1"))
    #expect(Redact.url("https://h/u/kid@example.com/x") == "https://h/u/[EMAIL]/x")
  }

  @Test func binaryAndHeaders() {
    #expect(Redact.body(Data([0xFF, 0xD8, 0x00, 0x01]), contentType: nil) as? String == "<binary 4 bytes>")
    let h = Redact.headers(["Authorization": "Bearer x", "Set-Cookie": "a=b", "Location": "https://x/?token=abc", "Accept": "*/*"])
    #expect(h["Authorization"] == "[REDACTED]" && h["Set-Cookie"] == "[REDACTED]" && h["Accept"] == "*/*")
    #expect(h["Location"]?.contains("abc") == false)
  }
}

// MARK: - Wi-Fi

/// Scripted network: the speaker's network appears after some scans; joining
/// it gives a 192.168.4.x address.
final class FakeNetwork: NetworkControl {
  var ssid: String?
  let speaker: String
  var speakerAppearsAfter: Int
  var scans = 0
  var canScan = true
  var joinHomeFails = false
  var calls: [String] = []

  init(ssid: String? = "Cohen", speaker: String = "MERLIN_TEST", speakerAppearsAfter: Int = 0) {
    self.ssid = ssid
    self.speaker = speaker
    self.speakerAppearsAfter = speakerAppearsAfter
  }

  var speakerVisible: Bool { scans > speakerAppearsAfter }
  func currentSSID() throws -> String? { ssid }
  func ip() -> String? { ssid.map { $0.hasPrefix("MERLIN") ? "192.168.4.2" : "10.0.0.12" } }

  func visibleSSIDs() throws -> [String] {
    scans += 1
    guard canScan else { return [] }
    return ["Cohen", "Voisins"] + (speakerVisible ? [speaker] : [])
  }

  func join(_ s: String, password: String?) throws {
    calls.append("join \(s) \(password ?? "-")")
    if s == speaker {
      if !canScan { scans += 1 } // without scanning, each attempt is how we "look"
      guard speakerVisible else { throw MerlinError("Could not find network \(s).") }
    } else if joinHomeFails {
      throw MerlinError("Failed to join network \(s).")
    }
    ssid = s
  }

  func forget(_ s: String) { calls.append("forget \(s)") }

  func powerCycle() throws {
    calls.append("power_cycle")
    ssid = "Cohen" // macOS auto-joins the preferred network
  }
}

@Suite struct WifiTests {
  static let timing = Wifi.Timing(poll: 0.01, joinWait: 0.5, giveUp: 5)

  @Test func fullRoundTrip() throws {
    let net = FakeNetwork(speakerAppearsAfter: 3)
    var out: [String] = []
    var statuses: [String] = []
    let wifi = Wifi(network: net, out: { out.append($0) }, onStatus: { statuses.append($0) }, timing: Self.timing)
    wifi.rememberHome()
    #expect(wifi.homeSSID == "Cohen")
    try wifi.joinSpeaker(ssid: "MERLIN_TEST", password: "pw")
    #expect(net.ssid == "MERLIN_TEST")
    #expect(net.calls == ["join MERLIN_TEST pw"], "joins only once the network is visible")
    #expect(statuses == ["Looking for MERLIN_TEST…", "Found MERLIN_TEST, joining…", "Connected to MERLIN_TEST"])
    #expect(out.contains("\(Wifi.ask): this Mac joins MERLIN_TEST by itself as soon as it appears."))
    wifi.restore()
    #expect(net.ssid == "Cohen")
    #expect(Array(net.calls.suffix(2)) == ["forget MERLIN_TEST", "join Cohen -"])
  }

  @Test func speakerNetworkIsNeverRememberedAsHome() {
    let wifi = Wifi(network: FakeNetwork(ssid: "MERLIN_DKCRG8"), out: { _ in }, timing: Self.timing)
    wifi.rememberHome()
    #expect(wifi.homeSSID == nil)
  }

  @Test func withoutLocationPermissionItKeepsTryingToJoin() throws {
    let net = FakeNetwork(speakerAppearsAfter: 3)
    net.canScan = false
    try Wifi(network: net, out: { _ in }, timing: Self.timing).joinSpeaker(ssid: "MERLIN_TEST", password: "pw")
    #expect(net.ssid == "MERLIN_TEST")
    #expect(net.calls.filter { $0.hasPrefix("join MERLIN_TEST") }.count > 1)
  }

  @Test func restoreLetsMacOSReconnectWhenHomeIsUnknownOrFails() throws {
    let net = FakeNetwork(ssid: nil)
    let wifi = Wifi(network: net, out: { _ in }, timing: Self.timing)
    wifi.rememberHome()
    try wifi.joinSpeaker(ssid: "MERLIN_TEST", password: "pw")
    wifi.restore()
    #expect(net.calls.last == "power_cycle")
    #expect(net.ssid == "Cohen")

    let net2 = FakeNetwork()
    let wifi2 = Wifi(network: net2, out: { _ in }, timing: Self.timing)
    wifi2.rememberHome()
    try wifi2.joinSpeaker(ssid: "MERLIN_TEST", password: "pw")
    net2.joinHomeFails = true
    wifi2.restore()
    #expect(net2.calls.last == "power_cycle")
  }

  @Test func givesUpIfTheSpeakerNeverAppears() {
    let wifi = Wifi(network: FakeNetwork(speakerAppearsAfter: .max), out: { _ in }, timing: Wifi.Timing(poll: 0.01, joinWait: 0.5, giveUp: 0.05))
    let error = #expect(throws: MerlinError.self) { try wifi.joinSpeaker(ssid: "MERLIN_TEST", password: "pw") }
    #expect(error?.message.contains("didn't show up") == true)
  }

  @Test func rejoinOnlyWhenOffTheSpeakerNetwork() throws {
    let net = FakeNetwork()
    let wifi = Wifi(network: net, out: { _ in }, timing: Self.timing)
    try wifi.joinSpeaker(ssid: "MERLIN_TEST", password: "pw")
    wifi.rejoinSpeaker()
    #expect(net.calls.filter { $0.hasPrefix("join") }.count == 1)
    net.ssid = "Cohen" // macOS wandered off
    wifi.rejoinSpeaker()
    #expect(net.ssid == "MERLIN_TEST")
  }
}

// MARK: - Traffic filter

/// Runs the real helper script without admin rights.
struct ShellLauncher: PrivilegedLauncher {
  var fail = false
  func launch(script: String, args: [String]) throws {
    if fail { throw CancellationError() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, "merlin-isolation"] + args
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
  }
}

/// Runs the real helper script against a fake pfctl that logs its arguments,
/// so no real firewall is touched.
@Suite(.serialized) final class IsolationTests {
  let dir = tempDir()
  var log: URL { dir.appendingPathComponent("pfctl.log") }
  var pfctl: URL { dir.appendingPathComponent("pfctl") }
  var iso: Isolation!

  init() throws {
    try """
    #!/bin/sh
    echo "$*" >> '\(log.path)'
    case "$*" in
      *"-f -"*) cat >> '\(log.path).rules' ;;
      "-E") [ -e '\(dir.path)/fail_E' ] && { echo "pfctl: permission denied"; exit 1; }
            echo "No ALTQ support in kernel"; echo "pf enabled"; echo "Token : 1234567890" ;;
    esac
    exit 0
    """.write(to: pfctl, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pfctl.path)
    iso = makeIsolation()
  }

  deinit {
    iso?.shutdownHelper()
    try? FileManager.default.removeItem(at: dir)
  }

  func makeIsolation(launcher: PrivilegedLauncher = ShellLauncher()) -> Isolation {
    Isolation(statePath: dir.appendingPathComponent("isolation.json"), interface: "en0", pfctl: pfctl.path, launcher: launcher)
  }

  var calls: [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  @Test func rulesOnlyLetTheTransferAndDHCPOutOfTheSpeakerSubnet() {
    #expect(iso.rules == """
    pass out quick on en0 proto tcp from 192.168.4.0/24 to 192.168.4.1 port 50000
    pass out quick on en0 proto udp from any port 68 to any port 67
    block out quick on en0 from 192.168.4.0/24 to any

    """)
  }

  /// One authorization (one password prompt) serves every sync of the session.
  @Test func oneHelperServesSeveralSyncsUntilShutdown() throws {
    try iso.authorize()
    for _ in 0..<2 {
      try iso.enable()
      #expect(iso.isActive)
      let state = try JSON.parse(Data(contentsOf: dir.appendingPathComponent("isolation.json"))) as! JSONObject
      #expect(state.str("token") == "1234567890")
      try iso.disable()
      #expect(!iso.isActive)
      #expect(!iso.hasLeftover)
      #expect(iso.isAuthorized, "the helper stays up for the next sync")
    }
    let once = ["-a com.apple/merlin -f -", "-E", "-a com.apple/merlin -F all", "-X 1234567890"]
    #expect(calls == once + once)
    #expect(try String(contentsOf: URL(fileURLWithPath: log.path + ".rules"), encoding: .utf8) == iso.rules + iso.rules)
    iso.shutdownHelper()
    #expect(!iso.isAuthorized)
  }

  @Test func leftoverFromACrashedRunIsCleanedBeforeEnabling() throws {
    try Data(#"{"token":"42"}"#.utf8).write(to: dir.appendingPathComponent("isolation.json"))
    try iso.authorize()
    try iso.enable()
    #expect(calls == ["-a com.apple/merlin -F all", "-X 42", "-a com.apple/merlin -f -", "-E"])
  }

  @Test func pfctlFailureIsReportedAndTheHelperStaysUsable() throws {
    let flag = dir.appendingPathComponent("fail_E")
    try Data().write(to: flag)
    try iso.authorize()
    let error = #expect(throws: MerlinError.self) { try iso.enable() }
    #expect(error?.message.contains("pfctl on failed: pfctl: permission denied") == true)
    #expect(iso.isAuthorized)
    try FileManager.default.removeItem(at: flag)
    try iso.enable() // a later sync can still use the same helper
  }

  @Test func nothingRunsWithoutAuthorization() {
    let error = #expect(throws: MerlinError.self) { try iso.enable() }
    #expect(error?.message.contains("admin rights") == true)
    #expect(calls.isEmpty)
  }

  @Test func cancelledAuthentication() {
    let other = makeIsolation(launcher: ShellLauncher(fail: true))
    let error = #expect(throws: MerlinError.self) { try other.authorize() }
    #expect(error?.message.contains("admin rights are needed") == true)
    #expect(!other.isAuthorized)
  }

  @Test func adminPromptQuoting() {
    #expect(AdminPromptLauncher.shellQuote("it's") == #"'it'\''s'"#)
    #expect(AdminPromptLauncher.appleScriptString(#"a "b" \c"#) == #""a \"b\" \\c""#)
  }
}

// MARK: - Covers

@Suite struct CoverTests {
  @Test func folderCoverIsA128JPEG() throws {
    let dest = tempDir().appendingPathComponent("c.jpg")
    try Media().folderCover("Les belles histoires de Pomme d'Api", dest)
    let src = CGImageSourceCreateWithURL(dest as CFURL, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 128)
    #expect(props[kCGImagePropertyPixelHeight] as? Int == 128)
  }

  @Test func longWordsShrinkTheFont() {
    let box = CGRect(x: 0, y: 0, width: 112, height: 112)
    #expect(Media.fittingSize("Supercalifragilistic", box: box) < Media.fittingSize("Lou", box: box))
  }

  @Test func zlibCRC() {
    #expect(Media.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
  }
}
