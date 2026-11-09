import Foundation

/// Re-implementation of the app's content synchronisation:
///
///   1. POST /synchros            -> plan (files, playlist JSON, settings)
///   2. download every file        (while still on the home network)
///   3. join the speaker's Wi-Fi, TCP 192.168.4.1:50000
///   4. upload images, then audio  (skipping files already on the speaker)
///   5. upload playlist-<id>.json, ask the speaker to apply it
///   6. set clock, enabling hours, home Wi-Fi config; end synchronisation
///   7. back on the home network:  PUT /synchros/<id> with the report
///
/// Blocking: run it on a background thread. Cancel through `speaker.cancel`.
public final class Sync: @unchecked Sendable {
  /// Safety net for genuine Wi-Fi hiccups. The long outages seen earlier were
  /// the speaker rebooting under the Mac's other traffic, which the traffic
  /// filter now prevents, so retries are quick.
  public static let linkRetries = 8
  public struct Timing {
    public var backoff: [Double] = [1, 1, 2, 2, 3, 3, 5, 5] // before each retry (22 s total)
    public var linkWindow = 5.0 // seconds allowed per reconnect attempt
    public var internetWait = 15.0
    public init() {}
  }

  public typealias Report = JSONObject

  private let backend: SyncBackend
  private let cacheDir: URL
  private let wifi: SyncWifi
  private let speakerOptions: SpeakerOptions
  private let out: SyncOutput
  private let isolation: TrafficFilter?
  private let content: SpeakerPlanContent?
  private let onTransferEnd: ((Report) -> Void)?
  private let timing: Timing
  private var cancel: CancelToken? { speakerOptions.cancel }

  private var logs: [String] = []
  private var speaker: Speaker?
  private var linkDown = true
  private var connectedOnce = false
  private var speakerSSID: String?

  /// content: what the speaker gets instead of the server's playlist (the
  /// library); nil keeps the plan as Merlin sent it.
  /// onTransferEnd: called once the speaker part is over (success or
  /// failure), before reconnecting and reporting to Merlin.
  public init(backend: SyncBackend, cacheDir: URL, wifi: SyncWifi, speaker: SpeakerOptions, out: SyncOutput,
              isolation: TrafficFilter? = nil, content: SpeakerPlanContent? = nil,
              onTransferEnd: ((Report) -> Void)? = nil, timing: Timing = Timing()) {
    self.backend = backend
    self.cacheDir = cacheDir
    self.wifi = wifi
    speakerOptions = speaker
    self.out = out
    self.isolation = isolation
    self.content = content
    self.onTransferEnd = onTransferEnd
    self.timing = timing
  }

  @discardableResult
  public func run(type: String = "TRANSFERT") throws -> JSONObject {
    resendPendingReport()

    say("Creating synchro on the Merlin backend...")
    var plan = try backend.createSynchro(type: type)
    guard let id = plan.id("id") else { throw MerlinError("the synchro plan has no id") }
    saveJSON("last_synchro.json", plan)
    // Merlin answered, so this is a network with internet: the one to come back to.
    wifi.rememberHome()
    say("Synchro \(id): \(plan.objs("fileList").count) file(s) in plan")

    // From here on every outcome is reported, so the synchro never stays PENDING.
    var report: Report = ["type": type]
    var offline = false
    defer {
      if offline {
        onTransferEnd?(report)
        unisolate()
        wifi.restore()
      }
      if !offline || waitForInternet() { sendReport(id, report) } else { savePendingReport(id, report) }
    }
    do {
      try applyContent(&plan)
      let files = try prepareFiles(plan)
      let playlist = try writePlaylist(plan)
      // No Merlin API call may happen from here until we're back online:
      // the speaker's access point has no internet.
      offline = true
      try isolate()
      try wifi.joinSpeaker(ssid: plan.str("ssid") ?? "", password: plan.str("password"))
      try transfer(plan, files, playlist, &report)
      report["status"] = "SUCCESS"
      report["status_code"] = "100_SUCCEED"
      say("Transfer complete.")
    } catch let e as SyncFailure {
      failReport(&report, e.code, e.message)
      throw e
    } catch let e as CancellationError {
      failReport(&report, "800_FAILED_ON_USER_ABORT", "aborted by user")
      throw e
    } catch {
      failReport(&report, "900_FAILED_ON_UNKNOW_ERROR", "\(Swift.type(of: error)): \(error.userMessage)")
      throw error
    }
    return plan
  }

  // MARK: Isolation

  /// Applied before joining: the rules only match the speaker subnet, so they
  /// are harmless at home and the speaker never sees the Mac's traffic burst.
  private func isolate() throws {
    guard let isolation else { return }
    try isolation.enable()
    log("Traffic filter on")
  }

  private func unisolate() {
    guard let isolation, isolation.isActive else { return }
    do {
      try isolation.disable()
      log("Traffic filter off")
    } catch {
      say("warning: could not remove the traffic filter (\(error.userMessage)); use Merlin › Remove Traffic Filter")
    }
  }

  /// After leaving the speaker's Wi-Fi, give the network time to come back
  /// before reporting; if it doesn't, the report is saved for later.
  /// Not cancellable: the report matters even after an abort.
  func waitForInternet() -> Bool {
    if backend.reachable() { return true }
    say("Waiting for internet access to send the report to Merlin...")
    let deadline = Date().addingTimeInterval(timing.internetWait)
    while !backend.reachable() {
      if Date() > deadline { return false }
      Thread.sleep(forTimeInterval: min(3, timing.internetWait))
    }
    return true
  }

  // MARK: Preparation

  private func prepareFiles(_ plan: JSONObject) throws -> [JSONObject] {
    let dir = cacheDir.appendingPathComponent("sync_files")
    do {
      let files = try plan.objs("fileList").map { f -> JSONObject in
        try cancel.check()
        if let path = f.str("path") { // from the library: nothing to download
          guard fileSize(URL(fileURLWithPath: path)) > 0 else { throw MerlinError("missing local file \(path)") }
          return f
        }
        guard let filename = f.str("filename"), let url = f.str("url") else { throw MerlinError("plan entry without filename/url") }
        let dest = dir.appendingPathComponent((filename as NSString).lastPathComponent)
        // Like the app: reuse any non-empty cached file. Don't compare with
        // "filesize" — the API reports a placeholder (20000) for images.
        if fileSize(dest) == 0 {
          say("  downloading \(f.str("type") ?? "") \(filename) (\(f.str("title") ?? ""))")
          try backend.download(url, to: dest, cancel: cancel)
        }
        var out = f
        out["path"] = dest.path
        return out
      }
      log("Prepare synchro content files succeed")
      return files
    } catch let e as CancellationError {
      throw e
    } catch {
      throw SyncFailure("202_FAILED_ON_PREPARE_CONTENT_FILES", error.userMessage)
    }
  }

  private func applyContent(_ plan: inout JSONObject) throws {
    guard let content else { return }
    do {
      try content.apply(to: &plan) { say($0) }
    } catch let e as CancellationError {
      throw e
    } catch {
      throw SyncFailure("203_FAILED_ON_PREPARE_CONTENT_PLAYLIST", "could not prepare the library for the speaker: \(error.userMessage)")
    }
  }

  private func writePlaylist(_ plan: JSONObject) throws -> URL {
    guard let text = plan["playlistText"] as? String else {
      throw SyncFailure("203_FAILED_ON_PREPARE_CONTENT_PLAYLIST", "plan has no playlistText")
    }
    let url = cacheDir.appendingPathComponent("playlist-\(plan.id("id") ?? "").json")
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    log("Save playlist file in cache succeed")
    return url
  }

  // MARK: Transfer

  private func transfer(_ plan: JSONObject, _ files: [JSONObject], _ playlist: URL, _ report: inout Report) throws {
    let host = speakerOptions.host, port = speakerOptions.port
    say("Connecting to the speaker at \(host):\(port)...")
    speakerSSID = plan.str("ssid")
    linkDown = true // the first connection goes through the same retry loop
    defer { speaker?.close() }
    do {
      do {
        try onSpeaker("connect") { _ in } // reconnectSpeaker connects and pings
      } catch let e as SpeakerError where e.isLink {
        throw SyncFailure("510_FAILED_ON_SDK_ESTABLISH_CONNEXION", "speaker not reachable at \(host):\(port): \(e.message)")
      }
      log("Connect to speaker succeed")
      try onSpeaker("read speaker info") { try readInfo($0, &report) }

      let images = files.filter { $0.str("type") == "image" } // images first, like the app
      let audios = files.filter { $0.str("type") == "audio" }
      var added = try uploadAll(images, kind: "image")
      added += try uploadAll(audios, kind: "audio")
      if report.str("type") == "TRANSFERT" { report["device_content_added"] = audios.count }
      say("  \(added) file(s) uploaded, \(files.count - added) already on the speaker")

      let name = playlist.lastPathComponent
      let playlistData = try Data(contentsOf: playlist)
      try onSpeaker("upload \(name)") { _ = try $0.syncFile(name, playlistData) }
      log("Upload playlist file on speaker succeed")
      say("Applying playlist (the speaker rebuilds its library; this can take a while)...")
      do {
        try onSpeaker("apply playlist") { try $0.updatePlaylist(name) }
      } catch let e as SpeakerError where !e.isLink {
        let code = e.message.contains("IMAGE_NOT_FOUND") ? "601_FAILED_ON_SDK_PLAYLIST_UPDATE_IMAGE_NOT_FOUND"
          : e.message.contains("MUSIC_NOT_FOUND") ? "602_FAILED_ON_SDK_PLAYLIST_UPDATE_AUDIO_NOT_FOUND"
          : "503_FAILED_ON_SDK_PLAYLIST_UPDATE"
        throw SyncFailure(code, "updatePlaylist: \(e.message)")
      }
      log("Update playlist on speaker succeed")

      try bestEffort("Set time on speaker") { try $0.setDate(Date()) }
      if let slot = plan.obj("time_slot") {
        let (week, weekend) = Self.enablingHours(slot)
        try bestEffort("Set enabling hours on speaker") { try $0.setEnablingHours(week, weekend) }
      }
      let pending = plan.str("pendingSsid")?.trimmingCharacters(in: .whitespaces) ?? ""
      if !pending.isEmpty {
        try bestEffort("Set Wifi configuration on speaker") { try $0.setWifi(ssid: pending, password: plan.str("pendingPassword") ?? "") }
      }
      try bestEffort("End synchronization") { try $0.endSynchronization() }
    } catch let e as SpeakerError {
      switch e.kind {
      case .timeout: throw SyncFailure("508_FAILED_ON_SDK_TIMEOUT", e.message)
      case .link: throw SyncFailure("509_FAILED_ON_SDK_CONNEXION_LOST", e.message)
      case .refused: throw SyncFailure("502_FAILED_ON_SDK_UPLOAD_FILE", e.message)
      }
    }
  }

  /// Runs a speaker operation; if the link fails (timeout, socket closed, TCP
  /// error) reconnects and tries again — the app does the same ("Rescue").
  /// A failed reconnect counts as one attempt. Answers from the speaker
  /// (e.g. NOT_ENOUGH_SPACE) are not retried.
  @discardableResult
  private func onSpeaker<T>(_ what: String, _ body: (Speaker) throws -> T) throws -> T {
    var attempt = 0
    while true {
      do {
        if linkDown { try reconnectSpeaker() }
        return try body(speaker!)
      } catch let e as SpeakerError where e.isLink {
        attempt += 1
        if attempt > Self.linkRetries { throw e }
        noteLinkProblem(what, e, attempt)
        linkDown = true
        try cancel.sleep(retryPause(attempt))
      }
    }
  }

  private func retryPause(_ attempt: Int) -> Double {
    attempt - 1 < timing.backoff.count ? timing.backoff[attempt - 1] : timing.backoff.last ?? 1
  }

  private func noteLinkProblem(_ what: String, _ error: SpeakerError, _ attempt: Int) {
    if connectedOnce {
      say("  speaker didn't respond during \(what) (\(error.message)); reconnecting in \(Self.fmt(retryPause(attempt)))s (retry \(attempt)/\(Self.linkRetries))...")
      if let ssid = speakerSSID, attempt == 1 { say("  (if this Mac left the speaker's Wi-Fi, rejoin \(ssid))") }
    } else {
      say("  speaker not reachable yet (\(error.message)); retrying (\(attempt)/\(Self.linkRetries))...")
    }
    trace("!! link problem during \(what): \(error.message) — \(networkSnapshot())")
  }

  static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

  /// One reconnect attempt, bounded by linkWindow: connect, then make sure the
  /// speaker actually answers (a just-rebooted speaker can accept TCP before
  /// it handles commands). In auto Wi-Fi mode, first rejoin its access point.
  private func reconnectSpeaker() throws {
    do {
      if connectedOnce {
        speaker?.close()
        wifi.rejoinSpeaker()
      }
      speaker = try connectWithRetry(timeout: timing.linkWindow)
      try speaker!.ping(timeout: min(speakerOptions.ackTimeout, 3))
      if connectedOnce {
        log("Reconnected to the speaker")
        trace("reconnected — \(networkSnapshot())")
      }
      connectedOnce = true
      linkDown = false
    } catch let e as SpeakerError where e.isLink {
      speaker?.close()
      if connectedOnce { trace("reconnect attempt failed: \(e.message) — \(networkSnapshot())") }
      throw e
    }
  }

  private func connectWithRetry(timeout: Double) throws -> Speaker {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      do {
        return try Speaker(speakerOptions).connect()
      } catch let e as SpeakerError {
        if Date() > deadline {
          throw SpeakerError.link("speaker not reachable at \(speakerOptions.host):\(speakerOptions.port): \(e.message)")
        }
        try cancel.sleep(min(2, timeout))
      }
    }
  }

  private func trace(_ msg: String) { speakerOptions.logger?(msg) }

  /// Which network the Mac is on right now (speaker AP is 192.168.4.x).
  private func networkSnapshot() -> String {
    let ip = MacNetwork.ipv4(of: "en0")
    let route = (try? Shell.run("/sbin/route", ["-n", "get", "default"]))?.text ?? ""
    let gw = route.range(of: #"gateway: (\S+)"#, options: .regularExpression).map { route[$0].dropFirst(9) }
    return "mac wifi ip=\(ip ?? "none") default gw=\(gw.map(String.init) ?? "none")"
  }

  private func readInfo(_ s: Speaker, _ report: inout Report) throws {
    let i = try s.info()
    say("Speaker: firmware \(i.firmwareVersion), battery \(i.batteryLevel)%\(i.charging ? " (charging)" : ""), \(i.availableSpace)/\(i.totalSize) free")
    report["firmware_version"] = i.firmwareVersion
    report["sd_size"] = Int(i.totalSize)
    report["available_size"] = Int(i.availableSpace)
    report["mac_address"] = i.macAddress
  }

  private func uploadAll(_ files: [JSONObject], kind: String) throws -> Int {
    var added = 0
    for (i, f) in files.enumerated() {
      let filename = f.str("filename") ?? ""
      let label = "  [\(kind) \(i + 1)/\(files.count)] \(filename)"
      let data = try Data(contentsOf: URL(fileURLWithPath: f.str("path") ?? ""))
      let result = try onSpeaker("\(kind) \(i + 1)/\(files.count) \(filename)") { s in
        try s.syncFile((filename as NSString).lastPathComponent, data) { sent, total in
          self.out.print("\r\(label) \(sent * 100 / max(total, 1))%")
        }
      }
      let outcome = result == .uploaded ? "uploaded" : "already present"
      out.print("\r\(label) \(outcome)\n")
      log("\(label.trimmingCharacters(in: .whitespaces)) (\(data.count) B) \(outcome)") // lands in the report
      if result == .uploaded { added += 1 }
    }
    log("Upload \(kind) files succeed")
    return added
  }

  /// Weekday window then weekend window; a disabled window is sent as
  /// 10:00-10:00, exactly like the app.
  static func enablingHours(_ slot: JSONObject) -> (Speaker.Window, Speaker.Window) {
    let off: Speaker.Window = ((10, 0), (10, 0))
    func hm(_ key: String) -> (Int, Int) {
      let parts = (slot.str(key) ?? "").split(separator: ":").map { Int($0) ?? 0 }
      return (parts.first ?? 10, parts.count > 1 ? parts[1] : 0)
    }
    let week = slot.flag("weekDayActive") ? (hm("weekDayStart"), hm("weekDayStop")) : off
    let weekend = slot.flag("weekEndActive") ? (hm("weekEndStart"), hm("weekEndStop")) : off
    return (week, weekend)
  }

  /// Optional steps: retried on link errors, otherwise failures are only logged.
  private func bestEffort(_ what: String, _ body: (Speaker) throws -> Void) throws {
    do {
      try onSpeaker(what.lowercased(), body)
      log("\(what) succeed")
    } catch let e as SpeakerError {
      log("\(what) failed, error ignored: \(e.message)")
      say("  warning: \(what.lowercased()) failed (\(e.message))")
    }
  }

  private func failReport(_ report: inout Report, _ code: String, _ message: String) {
    log(message)
    report["status"] = "FAIL"
    report["status_code"] = code
  }

  // MARK: Reporting

  private var pendingReportURL: URL { cacheDir.appendingPathComponent("pending_report.json") }

  private func reportBody(_ report: Report) -> JSONObject {
    var body = report
    body["logs"] = Array(logs.suffix(200))
    return body
  }

  private func sendReport(_ id: String, _ report: Report) {
    var lastError: Error?
    for attempt in 0..<3 {
      Thread.sleep(forTimeInterval: Double(attempt))
      do {
        try backend.reportSynchro(id: id, body: reportBody(report))
        try? FileManager.default.removeItem(at: pendingReportURL)
        say("Report sent to the Merlin backend.")
        return
      } catch {
        lastError = error
      }
    }
    savePendingReport(id, report, reason: lastError?.userMessage ?? "still offline")
  }

  private func savePendingReport(_ id: String, _ report: Report, reason: String = "still offline") {
    saveJSON("pending_report.json", ["id": id, "body": reportBody(report)])
    say("Report not sent (\(reason)); it will be sent at the next sync.")
  }

  private func resendPendingReport() {
    guard let data = try? Data(contentsOf: pendingReportURL),
          let pending = try? JSON.parse(data) as? JSONObject,
          let id = pending.id("id") else { return }
    if (try? backend.reportSynchro(id: id, body: pending.obj("body") ?? [:])) != nil {
      try? FileManager.default.removeItem(at: pendingReportURL)
    }
  }

  private func saveJSON(_ name: String, _ obj: JSONObject) {
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try? JSON.data(obj, pretty: true).write(to: cacheDir.appendingPathComponent(name))
  }

  private func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
  }

  private func log(_ msg: String) { logs.append(msg) }

  private func say(_ msg: String) {
    out.print(msg + "\n")
    log(msg)
  }
}

/// Where a sync's progress goes. "\r" rewrites the current line (progress).
public protocol SyncOutput: AnyObject {
  func print(_ text: String)
}

/// A thread-safe text log understanding "\r"; the UI reads `lines`.
public final class SyncLog: SyncOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var _lines: [String] = [""]
  public var onChange: (() -> Void)?

  public init() {}

  public func print(_ text: String) {
    lock.withLock {
      var current = _lines.removeLast()
      for ch in text {
        switch ch {
        case "\r": current = ""
        case "\n", "\r\n":
          _lines.append(current)
          current = ""
        default: current.append(ch)
        }
      }
      _lines.append(current)
    }
    onChange?()
  }

  public func line(_ text: String) { print(text + "\n") }

  public var lines: [String] {
    lock.withLock { _lines.last == "" ? Array(_lines.dropLast()) : _lines }
  }

  public var text: String { lines.joined(separator: "\n") }
}
