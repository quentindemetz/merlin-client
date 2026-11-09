import Foundation

/// Local state, shared with the Ruby CLI: ~/.config/merlin by default
/// (override with $MERLIN_HOME). Same files, same formats, so both tools see
/// the same login, speaker, library and logs.
public final class Config: @unchecked Sendable {
  public let home: URL
  private let lock = NSLock()
  private var cachedSettings: JSONObject?

  public init(home: URL? = nil) {
    if let home {
      self.home = home
    } else if let env = ProcessInfo.processInfo.environment["MERLIN_HOME"], !env.isEmpty {
      self.home = URL(fileURLWithPath: env)
    } else {
      self.home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/merlin")
    }
  }

  public var settingID: String? {
    get { settings.id("setting_id") }
    set { saveSettings(["setting_id": newValue ?? NSNull()]) }
  }

  public var tokenStore: TokenStore { TokenStore(url: home.appendingPathComponent("tokens.json")) }
  public var cacheDir: URL { home.appendingPathComponent("cache") }
  public var logDir: URL { home.appendingPathComponent("logs") }
  public var isolationStateURL: URL { home.appendingPathComponent("isolation.json") }

  public var settings: JSONObject {
    lock.withLock {
      if let cachedSettings { return cachedSettings }
      let url = home.appendingPathComponent("config.json")
      let parsed = (try? Data(contentsOf: url)).flatMap { try? JSON.parse($0) as? JSONObject } ?? [:]
      cachedSettings = parsed
      return parsed
    }
  }

  public func saveSettings(_ values: JSONObject) {
    var merged = settings
    for (k, v) in values { merged[k] = v }
    lock.withLock {
      cachedSettings = merged
      try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      try? JSON.data(merged, pretty: true).write(to: home.appendingPathComponent("config.json"), options: .atomic)
    }
  }
}

/// Persists OAuth tokens (never the password) in a 0600 JSON file.
public struct TokenStore {
  public let url: URL

  public func load() -> JSONObject? {
    (try? Data(contentsOf: url)).flatMap { try? JSON.parse($0) as? JSONObject }
  }

  public func save(_ tokens: JSONObject?) {
    guard let tokens else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard let data = try? JSON.data(tokens, pretty: true) else { return }
    FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
  }
}
