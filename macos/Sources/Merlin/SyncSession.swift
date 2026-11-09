import Foundation
import MerlinCore
import Observation

/// One synchronisation, running on a background thread.
///
/// The session is "finished" as soon as the speaker part is over (its
/// outcome is known); getting back online and reporting to Merlin happens
/// afterwards, still in the background ("reporting").
@MainActor @Observable
final class SyncSession {
  enum State: Equatable { case running, done, failed, aborted }

  struct Waiting: Equatable {
    let ssid: String
    var status: String
  }

  private(set) var state: State = .running
  private(set) var reporting = false
  private(set) var lines: [String] = []
  private(set) var waiting: Waiting?
  private(set) var homeSSID: String?
  private(set) var errorMessage: String?
  private(set) var aborting = false

  @ObservationIgnored let log = SyncLog()
  @ObservationIgnored private let cancel = CancelToken()
  @ObservationIgnored private let finished = DispatchSemaphore(value: 0)
  @ObservationIgnored private var refreshPending = false
  @ObservationIgnored private weak var app: AppModel?
  @ObservationIgnored private var sync: Sync!
  @ObservationIgnored private let isolation: Isolation?

  var isRunning: Bool { state == .running }
  var isFinished: Bool { !isRunning }
  /// Still busy in the background: speaker part, or reconnecting/reporting.
  var isActive: Bool { isRunning || reporting }

  init(app: AppModel, isolation: Isolation?) {
    self.app = app
    self.isolation = isolation
    let log = log
    let cancel = cancel
    let speakerLog = app.speakerLog
    let wifi = SessionWifi(network: app.network, log: log, cancel: cancel)
    isolation?.out = { log.line($0) }
    sync = Sync(
      backend: app.backend, cacheDir: app.config.cacheDir, wifi: wifi,
      speaker: SpeakerOptions(logger: { speakerLog($0) }, cancel: cancel),
      out: log, isolation: isolation,
      content: app.library.flatMap { lib in
        app.settingID.map {
          SpeakerPlaylist(library: lib, settingID: $0, coverDir: app.config.cacheDir.appendingPathComponent("speaker_covers"),
                          convertedDir: app.config.cacheDir.appendingPathComponent("converted"), cancel: cancel)
        }
      },
      onTransferEnd: { [weak self] report in
        let outcome: State = report.str("status") == "SUCCESS" ? .done
          : (report.str("status_code") ?? "").hasPrefix("800") ? .aborted : .failed
        DispatchQueue.main.async { self?.finishSpeakerPart(outcome) }
      }
    )
    wifi.onChange = { [weak self] waiting, home in
      DispatchQueue.main.async {
        self?.waiting = waiting
        self?.homeSSID = home
      }
    }
    log.onChange = { [weak self] in
      DispatchQueue.main.async { self?.scheduleRefresh() }
    }
  }

  func start() {
    let sync: Sync = sync
    let finished = finished
    let thread = Thread { [weak self] in
      var outcome: State = .done
      var message: String?
      do {
        try sync.run()
      } catch is CancellationError {
        outcome = .aborted
      } catch {
        outcome = .failed
        message = error.userMessage
      }
      DispatchQueue.main.async {
        guard let self else { return }
        if outcome == .aborted { self.log.line("Aborted.") } else if let message { self.log.line("Error: \(message)") }
        self.errorMessage = message
        if self.state == .running { self.state = outcome }
        self.reporting = false
        self.waiting = nil
        self.refresh()
        self.app?.syncEnded()
      }
      finished.signal()
    }
    thread.name = "Merlin sync"
    thread.start()
  }

  func abort() {
    aborting = true
    cancel.cancel()
  }

  /// Leaving the app: let a sync that is reconnecting / reporting finish
  /// (bounded: Wi-Fi restore and the internet wait are both time-limited).
  nonisolated func waitUntilFinished(timeout: Double) {
    _ = finished.wait(timeout: .now() + timeout)
  }

  private func finishSpeakerPart(_ outcome: State) {
    guard state == .running else { return }
    state = outcome
    reporting = true
    waiting = nil
  }

  private func scheduleRefresh() {
    guard !refreshPending else { return }
    refreshPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.refreshPending = false
      self?.refresh()
    }
  }

  private func refresh() { lines = log.lines }
}

/// Wi-Fi switching for the app: the core's automatic switching, plus what
/// the sync screen needs for its "switch the speaker on" prompt.
final class SessionWifi: SyncWifi, @unchecked Sendable {
  private var wifi: Wifi!
  private var waiting: SyncSession.Waiting?
  var onChange: ((SyncSession.Waiting?, String?) -> Void)?

  init(network: NetworkControl, log: SyncLog, cancel: CancelToken) {
    wifi = Wifi(network: network, out: { log.line($0) }, onStatus: { [weak self] msg in
      guard let self, var w = self.waiting else { return }
      w.status = msg
      self.waiting = w
      self.publish()
    }, cancel: cancel)
  }

  private func publish() { onChange?(waiting, wifi.homeSSID) }

  func rememberHome() {
    wifi.rememberHome()
    publish()
  }

  func joinSpeaker(ssid: String, password: String?) throws {
    waiting = SyncSession.Waiting(ssid: ssid, status: Wifi.ask)
    publish()
    defer {
      waiting = nil
      publish()
    }
    try wifi.joinSpeaker(ssid: ssid, password: password)
  }

  func rejoinSpeaker() { wifi.rejoinSpeaker() }
  func restore() { wifi.restore() }
}
