import Foundation

/// What a sync needs from Wi-Fi switching (tests use a stub).
public protocol SyncWifi: AnyObject {
  func rememberHome()
  func joinSpeaker(ssid: String, password: String?) throws
  func rejoinSpeaker()
  func restore()
}

/// Switching this Mac between its usual Wi-Fi and the speaker's access point:
///
/// 1. rememberHome — right after talking to the Merlin API, note the network
///    we're on (needs Location Services).
/// 2. joinSpeaker  — wait for the speaker's network to appear (the user
///    switches the speaker on and presses Wifi / Transfert) and join it.
/// 3. restore      — whatever the outcome, forget the speaker network and
///    reconnect to the remembered one.
public final class Wifi: SyncWifi, @unchecked Sendable {
  public static let speakerSubnet = "192.168.4."
  public static let ask = "Switch the speaker on and press its Wifi / Transfert button"

  /// Seconds between scans, to wait for a join to take, and before giving up.
  public struct Timing {
    public var poll = 3.0, joinWait = 20.0, giveUp = 600.0
    public init(poll: Double = 3, joinWait: Double = 20, giveUp: Double = 600) {
      self.poll = poll
      self.joinWait = joinWait
      self.giveUp = giveUp
    }
  }

  public private(set) var homeSSID: String?
  public private(set) var status: String?

  private let network: NetworkControl
  private let out: (String) -> Void
  private let onStatus: ((String) -> Void)?
  private let timing: Timing
  private let cancel: CancelToken?
  private var speakerSSID: String?
  private var speakerPassword: String?

  public init(network: NetworkControl, out: @escaping (String) -> Void, onStatus: ((String) -> Void)? = nil,
              timing: Timing = Timing(), cancel: CancelToken? = nil) {
    self.network = network
    self.out = out
    self.onStatus = onStatus
    self.timing = timing
    self.cancel = cancel
  }

  public func rememberHome() {
    do {
      if let ssid = try network.currentSSID(), !ssid.uppercased().hasPrefix("MERLIN") {
        homeSSID = ssid
        out("Will reconnect to \"\(ssid)\" after the transfer.")
      } else {
        out("Couldn't read this Mac's Wi-Fi name (Location Services for Merlin?): macOS will pick the network back after the transfer.")
      }
    } catch {
      out("Couldn't read this Mac's Wi-Fi name (\(error.userMessage)).")
    }
  }

  public func joinSpeaker(ssid: String, password: String?) throws {
    speakerSSID = ssid
    speakerPassword = password
    let deadline = Date().addingTimeInterval(timing.giveUp)
    if !onSpeaker { out("\(Self.ask): this Mac joins \(ssid) by itself as soon as it appears.") }
    updateStatus("Looking for \(ssid)…")
    while !onSpeaker {
      try cancel.check()
      if Date() > deadline {
        throw MerlinError("the speaker's Wi-Fi \(ssid) didn't show up within \(Int(timing.giveUp / 60)) minutes")
      }
      let nets = scan()
      if nets == nil || nets!.contains(ssid) { // can't scan (no permission): just try
        if nets != nil { updateStatus("Found \(ssid), joining…") }
        try tryJoin()
      } else {
        updateStatus("Looking for \(ssid)…")
        try cancel.sleep(timing.poll)
      }
    }
    updateStatus("Connected to \(ssid)")
    out("Joined the speaker's Wi-Fi \(ssid).")
  }

  /// After a dropped link during the transfer: rejoin if we've left it.
  public func rejoinSpeaker() {
    guard !onSpeaker, let ssid = speakerSSID else { return }
    out("Rejoining the speaker's Wi-Fi \(ssid)…")
    try? tryJoin()
  }

  /// Not cancellable: getting the Mac back online always runs to the end.
  public func restore() {
    if let ssid = speakerSSID { network.forget(ssid) }
    do {
      if let home = homeSSID {
        out("Reconnecting to \"\(home)\"…")
        do {
          try network.join(home, password: nil)
        } catch {
          out("Couldn't join \"\(home)\" (\(error.userMessage)); letting macOS reconnect.")
          try network.powerCycle()
        }
      } else {
        out("Reconnecting Wi-Fi to your usual network…")
        try network.powerCycle()
      }
      let deadline = Date().addingTimeInterval(timing.joinWait)
      while onSpeaker && Date() < deadline { Thread.sleep(forTimeInterval: min(1, timing.joinWait)) }
    } catch {
      out("Could not reconnect automatically: \(error.userMessage) (reconnect manually)")
    }
  }

  private var onSpeaker: Bool { network.ip()?.hasPrefix(Self.speakerSubnet) ?? false }

  /// nil when scanning isn't possible (no location permission → no names).
  private func scan() -> [String]? {
    guard let nets = try? network.visibleSSIDs(), !nets.isEmpty else { return nil }
    return nets
  }

  private func tryJoin() throws {
    guard let ssid = speakerSSID else { return }
    do {
      try network.join(ssid, password: speakerPassword)
    } catch {
      try cancel.sleep(timing.poll) // not there yet
      return
    }
    let deadline = Date().addingTimeInterval(timing.joinWait)
    while !onSpeaker && Date() < deadline { try cancel.sleep(min(1, timing.joinWait)) }
  }

  private func updateStatus(_ msg: String) {
    guard msg != status else { return }
    status = msg
    onStatus?(msg)
  }
}
