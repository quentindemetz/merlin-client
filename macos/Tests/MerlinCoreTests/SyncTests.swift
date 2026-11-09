import Foundation
import Testing
@testable import MerlinCore

/// Simulated network: while the laptop is on the speaker's access point the
/// Merlin API is unreachable, and any attempt to use it is recorded.
final class SimNet {
  var onSpeaker = false
  var userReconnects = true
  var offlineCalls: [String] = []
}

final class StubBackend: SyncBackend {
  var plan: JSONObject
  let contents: [String: Data]
  let net: SimNet
  var reports: [(String, JSONObject)] = []
  var downloads: [String] = []
  var failReports = false
  var failDownloads = false

  init(plan: JSONObject, contents: [String: Data], net: SimNet) {
    self.plan = plan
    self.contents = contents
    self.net = net
  }

  func reachable() -> Bool { !net.onSpeaker }

  func createSynchro(type: String) throws -> JSONObject {
    try guardOnline("create_synchro")
    var p = plan
    p["type"] = type
    return p
  }

  func download(_ url: String, to dest: URL, cancel: CancelToken?) throws {
    try guardOnline("download")
    if failDownloads { throw MerlinError("bad URI") }
    downloads.append(url)
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents[url]!.write(to: dest)
  }

  func reportSynchro(id: String, body: JSONObject) throws {
    try guardOnline("report_synchro")
    if failReports { throw BackendError("server error") }
    reports.append((id, body))
  }

  private func guardOnline(_ call: String) throws {
    guard net.onSpeaker else { return }
    net.offlineCalls.append(call)
    throw BackendError("can't reach api.hello-merlin.com", offline: true)
  }
}

final class NoWifi: SyncWifi {
  let net: SimNet
  var events: [String]?
  init(_ net: SimNet, events: [String]? = nil) {
    self.net = net
    self.events = events
  }
  func rememberHome() {}
  func joinSpeaker(ssid: String, password: String?) throws { events?.append("join"); net.onSpeaker = true }
  func rejoinSpeaker() {}
  func restore() { events?.append("restore"); net.onSpeaker = !net.userReconnects }
}

final class FakeIsolation: TrafficFilter {
  var events: [String] = []
  var failEnable = false
  private(set) var isActive = false
  func enable() throws {
    if failEnable { throw MerlinError("pfctl -E failed") }
    isActive = true
    events.append("filter_on")
  }
  func disable() throws {
    isActive = false
    events.append("filter_off")
  }
}

final class Captured: SyncOutput {
  var text = ""
  func print(_ s: String) { text += s }
}

struct FakeMedia: MediaTools {
  func probe(_ path: URL) throws -> MediaInfo {
    MediaInfo(title: "Histoire de papa", duration: 60, codec: "pcm_s16le", sampleRate: 48_000, channels: 1, bitRate: 768_000, hasCover: false)
  }
  func prepareAudio(_ src: URL, _ dest: URL, _ info: MediaInfo) throws -> ImportAction {
    try Data("MP3 of papa".utf8).write(to: dest)
    return .transcoded
  }
  func extractCover(_ src: URL, _ dest: URL, _ info: MediaInfo) throws -> Bool { false }
  func encodeMP3(_ src: URL, _ dest: URL, kbps: Int) throws { try Data("MP3 \(kbps)k of papa".utf8).write(to: dest) }
  func folderCover(_ title: String, _ dest: URL) throws { try Data("cover titled \(title)".utf8).write(to: dest) }
}

func tempDir() -> URL {
  let d = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-test-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
  return d
}

let playlist = #"[{"uuid":"u1","title":"Contes","child":[{"uuid":"a1","title":"Le loup"}]}]"#

@Suite(.serialized)
final class SyncTests {
  let fake = FakeSpeaker()
  let dir = tempDir()
  let audio: Data
  let net = SimNet()
  let backend: StubBackend

  init() {
    var g = SystemRandomNumberGenerator()
    audio = Data((0..<250_000).map { _ in UInt8.random(in: 0...255, using: &g) })
    let plan: JSONObject = [
      "id": "syn-42",
      "fileList": [
        ["type": "audio", "url": "https://cdn/a1.mp3", "filename": "a1.mp3", "title": "Le loup", "filesize": 250_000],
        ["type": "image", "url": "https://cdn/u1.jpg", "filename": "u1.jpg", "title": "Contes"],
      ],
      "playlistText": playlist,
      "time_slot": ["weekDayActive": true, "weekDayStart": "07:30", "weekDayStop": "19:45",
                    "weekEndActive": false, "weekEndStart": "08:00", "weekEndStop": "20:00"],
      "pendingSsid": "Home", "pendingPassword": "pw",
    ]
    backend = StubBackend(plan: plan, contents: ["https://cdn/a1.mp3": audio, "https://cdn/u1.jpg": Data("JPEGDATA".utf8)], net: net)
  }

  deinit {
    fake.stop()
    try? FileManager.default.removeItem(at: dir)
  }

  static var fast: Sync.Timing {
    var t = Sync.Timing()
    t.backoff = Array(repeating: 0.01, count: Sync.linkRetries)
    t.linkWindow = 0.5
    t.internetWait = 0
    return t
  }

  func sync(out: Captured = Captured(), ackTimeout: Double = Speaker.ackTimeout, port: Int? = nil, logger: ((String) -> Void)? = nil,
            wifi: SyncWifi? = nil, isolation: TrafficFilter? = nil, content: SpeakerPlanContent? = nil,
            onTransferEnd: ((JSONObject) -> Void)? = nil, timing: Sync.Timing = SyncTests.fast) -> Sync {
    Sync(backend: backend, cacheDir: dir, wifi: wifi ?? NoWifi(net),
         speaker: SpeakerOptions(host: "127.0.0.1", port: port ?? fake.port, logger: logger, ackTimeout: ackTimeout),
         out: out, isolation: isolation, content: content, onTransferEnd: onTransferEnd, timing: timing)
  }

  var lastReport: JSONObject { backend.reports.last?.1 ?? [:] }

  @Test func fullSync() throws {
    try sync().run()
    #expect(fake.files["a1.mp3"] == [UInt8](audio))
    #expect(fake.file("u1.jpg") == "JPEGDATA")
    #expect(fake.file("playlist-syn-42.json") == playlist)
    #expect(fake.playlistUpdates == ["playlist-syn-42.json"])
    #expect(fake.hours == [7, 30, 19, 45, 10, 0, 10, 0])
    #expect(fake.wifi?.0 == "Home" && fake.wifi?.1 == "pw")
    #expect(fake.date != nil)
    #expect(fake.commands.contains(WireProtocol.Cmd.endSynchronization))
    #expect(backend.reports.last?.0 == "syn-42")
    #expect(lastReport.str("status") == "SUCCESS")
    #expect(lastReport.str("status_code") == "100_SUCCEED")
    #expect(lastReport.str("type") == "TRANSFERT")
    #expect(lastReport.str("firmware_version") == "1.4.27")
    #expect(lastReport.int("sd_size") == 8_000_000)
    #expect(net.offlineCalls.isEmpty, "Merlin API was called while on the speaker's Wi-Fi")
  }

  /// The filter must be on before joining the speaker's Wi-Fi and off once
  /// the speaker part is over, before going back home.
  @Test func trafficFilterWrapsTheSpeakerPart() throws {
    let iso = FakeIsolation()
    let wifi = NoWifi(net, events: [])
    var ended = false
    try sync(wifi: wifi, isolation: iso, onTransferEnd: { _ in ended = true; iso.events.append("transfer_end") }).run()
    #expect(ended)
    #expect(iso.events == ["filter_on", "transfer_end", "filter_off"])
    #expect(wifi.events == ["join", "restore"])
    #expect(lastReport.str("status") == "SUCCESS")
  }

  @Test func doesNotJoinTheSpeakerIfTheFilterCannotBeApplied() {
    let iso = FakeIsolation()
    iso.failEnable = true
    let wifi = NoWifi(net, events: [])
    #expect(throws: MerlinError.self) { try sync(wifi: wifi, isolation: iso).run() }
    #expect(!(wifi.events ?? []).contains("join"))
    #expect(lastReport.str("status") == "FAIL")
  }

  @Test func theLibraryReplacesTheServersContent() throws {
    let lib = try MediaLibrary(root: dir.appendingPathComponent("Library"))
    let folder = try lib.addFolder("Mes histoires", section: "contes") // matches "Contes" without case
    let src = dir.appendingPathComponent("papa.wav")
    try Data("RIFF".utf8).write(to: src)
    let (track, _) = try lib.importFile(src, into: .folder(folder.id), media: FakeMedia())

    let out = Captured()
    let content = SpeakerPlaylist(library: lib, settingID: "s1", coverDir: dir.appendingPathComponent("covers"), media: FakeMedia())
    try sync(out: out, content: content).run()
    #expect(fake.file("\(track.id).mp3") == "MP3 of papa")
    #expect(fake.files["\(track.id).jpg"]?.isEmpty == false) // a default cover
    #expect(fake.file("\(folder.id).jpg") == "cover titled Mes histoires")
    #expect(fake.file("u1.jpg") == "JPEGDATA") // the section keeps Merlin's cover
    #expect(fake.files["a1.mp3"] == nil, "the server's episode is replaced")
    let tree = try JSON.parse(fake.file("playlist-syn-42.json")!) as! [JSONObject]
    #expect(tree.map { $0.str("title") } == ["Contes"])
    let kids = tree[0].objs("child")
    #expect(kids.map { $0.str("title") } == ["Mes histoires"])
    #expect(kids[0].objs("child").map { $0.str("title") } == ["Histoire de papa"])
    #expect(backend.downloads == ["https://cdn/u1.jpg"], "library files are never downloaded")
    #expect(out.text.contains("Sending 1 episode(s) in 1 folder(s) from your library"))
    #expect(lib.sections().first == "Contes", "the speaker's sections are remembered")
    #expect(lastReport.str("status") == "SUCCESS")
  }

  @Test func userNeverReconnectsReportIsKeptForLater() throws {
    net.userReconnects = false
    let out = Captured()
    try sync(out: out).run()
    #expect(net.offlineCalls.isEmpty, "no API attempt should be made while still offline")
    #expect(backend.reports.isEmpty)
    #expect(out.text.contains("will be sent at the next sync"))
    let pending = try JSON.parse(Data(contentsOf: dir.appendingPathComponent("pending_report.json"))) as! JSONObject
    #expect(pending.str("id") == "syn-42" && pending.obj("body")?.str("status") == "SUCCESS")

    net.onSpeaker = false
    net.userReconnects = true
    try sync().run()
    #expect(backend.reports.map { $0.1.str("status") } == ["SUCCESS", "SUCCESS"])
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pending_report.json").path))
  }

  /// The speaker stops answering an upload: reconnect and carry on.
  @Test func recoversWhenSpeakerStopsAnsweringAnUpload() throws {
    fake.silentUploads = [2] // the audio file (images go first)
    let out = Captured()
    try sync(out: out, ackTimeout: 0.1).run()
    #expect(fake.files["a1.mp3"] == [UInt8](audio))
    #expect(fake.file("playlist-syn-42.json") == playlist)
    #expect(fake.connections == 2)
    #expect(out.text.range(of: #"speaker didn't respond during audio 1/1 a1\.mp3 .*reconnecting in [\d.]+s \(retry 1/8\)"#, options: .regularExpression) != nil)
    #expect(lastReport.str("status") == "SUCCESS")
    let logs = lastReport["logs"] as? [String] ?? []
    #expect(logs.contains { $0.contains("[audio 1/1] a1.mp3 (250000 B) uploaded") }, "per-file results are reported")
  }

  @Test func reconnectSurvivesASpeakerNotReadyYet() throws {
    fake.silentUploads = [2]
    fake.silentPings = [2] // 1 = initial ping, 2 = first ping after reconnecting
    let traces = Locked<[String]>([])
    try sync(ackTimeout: 0.1, logger: { m in traces.mutate { $0.append(m) } }).run()
    #expect(lastReport.str("status") == "SUCCESS")
    #expect(fake.connections == 3)
    let t = traces.value
    #expect(t.contains { $0.hasPrefix("!! link problem during audio 1/1 a1.mp3") && $0.contains("mac wifi ip=") })
    #expect(t.contains { $0.hasPrefix("reconnect attempt failed: timed out waiting for cmd 2") })
    #expect(t.contains { $0.hasPrefix("reconnected — mac wifi ip=") })
  }

  @Test func ridesOutSpeakerResettingNewConnections() throws {
    fake.silentUploads = [2]
    fake.resetAfterDrop = 3
    let out = Captured()
    try sync(out: out, ackTimeout: 0.1).run()
    #expect(lastReport.str("status") == "SUCCESS")
    #expect(fake.files["a1.mp3"] == [UInt8](audio))
    #expect(fake.connections == 5) // working, 3 reset at once, working again
    #expect(out.text.range(of: "the speaker (reset|closed) the connection|socket closed by speaker", options: .regularExpression) != nil)
  }

  @Test func ridesOutSeveralConsecutiveFailures() throws {
    fake.silentUploads = Set(2...6)
    try sync(ackTimeout: 0.1).run()
    #expect(lastReport.str("status") == "SUCCESS")
    #expect(fake.connections == 6)
  }

  @Test func givesUpAfterAllRetriesWhenSpeakerStaysSilent() {
    fake.silentUploads = Set(2...100)
    let error = #expect(throws: SyncFailure.self) { try sync(ackTimeout: 0.1).run() }
    #expect(error?.code == "508_FAILED_ON_SDK_TIMEOUT")
    #expect(fake.connections == 1 + Sync.linkRetries) // first try + one reconnect per retry
    #expect(lastReport.str("status_code") == "508_FAILED_ON_SDK_TIMEOUT")
  }

  @Test func unreachableAtFirstIsRetriedThenReportedAsConnectionFailure() {
    let closed = FakeSpeaker()
    let port = closed.port
    closed.stop()
    var timing = Self.fast
    timing.linkWindow = 0
    let out = Captured()
    let error = #expect(throws: SyncFailure.self) { try sync(out: out, port: port, timing: timing).run() }
    #expect(error?.code == "510_FAILED_ON_SDK_ESTABLISH_CONNEXION")
    #expect(out.text.components(separatedBy: "speaker not reachable yet").count - 1 == Sync.linkRetries)
  }

  @Test func speakerRefusalIsNotRetried() {
    fake.uploadRefusal = 2 // NOT_ENOUGH_SPACE
    let error = #expect(throws: SyncFailure.self) { try sync(ackTimeout: 0.1).run() }
    #expect(error?.code == "502_FAILED_ON_SDK_UPLOAD_FILE")
    #expect(error?.message.contains("NOT_ENOUGH_SPACE") == true)
    #expect(fake.connections == 1)
  }

  @Test func speakerLogTracesTheProtocolWithoutWifiCredentials() throws {
    let lines = Locked<[String]>([])
    try sync(logger: { m in lines.mutate { $0.append(m) } }).run()
    let trace = lines.value.joined(separator: "\n")
    #expect(trace.contains("-> upload_file a1.mp3 (250000 B)"))
    #expect(trace.range(of: #"<- upload_file SHA256_VALID \[\d+ms\]"#, options: .regularExpression) != nil)
    #expect(trace.contains("-> search_file u1.jpg verify=true"))
    #expect(trace.contains("-> update_playlist playlist-syn-42.json"))
    #expect(trace.contains("-> set_wifi [REDACTED]"))
    #expect(!trace.contains("Home"))
  }

  @Test func secondSyncSkipsDownloadsAndUploads() throws {
    try sync().run()
    let out = Captured()
    try sync(out: out).run()
    #expect(backend.downloads.count == 2)
    #expect(out.text.contains("0 file(s) uploaded, 2 already on the speaker"))
  }

  @Test func downloadFailureIsReported() {
    backend.failDownloads = true
    let error = #expect(throws: SyncFailure.self) { try sync().run() }
    #expect(error?.code == "202_FAILED_ON_PREPARE_CONTENT_FILES")
    #expect(lastReport.str("status") == "FAIL")
    #expect(lastReport.str("status_code") == "202_FAILED_ON_PREPARE_CONTENT_FILES")
  }

  @Test func playlistFailureIsReported() {
    backend.plan["playlistText"] = nil
    #expect(throws: SyncFailure.self) { try sync().run() }
    #expect(lastReport.str("status_code") == "203_FAILED_ON_PREPARE_CONTENT_PLAYLIST")
  }

  @Test func abortIsReportedAsUserAbort() {
    fake.silentUploads = Set(2...100)
    let token = CancelToken()
    let s = Sync(backend: backend, cacheDir: dir, wifi: NoWifi(net),
                 speaker: SpeakerOptions(host: "127.0.0.1", port: fake.port, ackTimeout: 5, cancel: token),
                 out: Captured(), timing: Self.fast)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { token.cancel() }
    let started = Date()
    #expect(throws: CancellationError.self) { try s.run() }
    #expect(Date().timeIntervalSince(started) < 3, "aborting doesn't wait for the 5 s timeout")
    #expect(lastReport.str("status_code") == "800_FAILED_ON_USER_ABORT")
  }
}

final class Locked<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var v: T
  init(_ v: T) { self.v = v }
  var value: T { lock.withLock { v } }
  func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
