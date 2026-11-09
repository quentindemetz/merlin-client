import Foundation

/// What a sync needs from the Merlin cloud (tests use a stub).
public protocol SyncBackend: AnyObject {
  func createSynchro(type: String) throws -> JSONObject
  func download(_ url: String, to dest: URL, cancel: CancelToken?) throws
  func reportSynchro(id: String, body: JSONObject) throws
  func reachable() -> Bool
}

/// Client for the Hello Merlin cloud API (the app's Retrofit services).
/// Calls are synchronous: run them off the main thread. Thread-safe.
public final class Backend: SyncBackend, @unchecked Sendable {
  public static let apiBase = URL(string: "https://api.hello-merlin.com/api/v1/")!
  public static let tokenURL = URL(string: "https://sso.hello-merlin.com/auth/realms/hello-merlin/protocol/openid-connect/token")!
  static let appVersion = "1.20.5"
  static let appBuild = "1020005"
  public static let userAgent = "Merlin/\(appVersion) Dalvik/2.1.0 (Linux; U; Android 14)"
  static let appHeaders = [
    "User-Agent": userAgent,
    "X-Merlin-App-Version": appVersion,
    "X-Merlin-App-Build": appBuild,
    "X-Merlin-OS": "Android",
    "X-Merlin-OS-Version": "14",
  ]
  /// Bounds the connect and every stall between packets, so a dead network
  /// (e.g. the speaker's access point) fails fast while long downloads that
  /// keep making progress are unaffected.
  static let apiTimeout = 10.0

  /// The app builds SynchroBody with Kotlin defaults, which force
  /// start = end = "" and active = true; the API answers a bare 400 without them.
  static let synchroDefaults: JSONObject = ["start": "", "end": "", "active": true, "device_content_added": 0]

  private let tokenStore: TokenStore
  private let lock = NSRecursiveLock()
  private var tokens: JSONObject?
  private var _settingID: String?
  public let httpLog: HttpLog?
  private let session: URLSession
  private let apiBase: URL
  private let tokenURL: URL

  public init(tokenStore: TokenStore, settingID: String? = nil, httpLog: HttpLog? = nil,
              apiBase: URL = Backend.apiBase, tokenURL: URL = Backend.tokenURL) {
    self.tokenStore = tokenStore
    tokens = tokenStore.load()
    _settingID = settingID
    self.httpLog = httpLog
    self.apiBase = apiBase
    self.tokenURL = tokenURL
    let config = URLSessionConfiguration.ephemeral
    config.httpAdditionalHeaders = Self.appHeaders
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.waitsForConnectivity = false
    session = URLSession(configuration: config)
  }

  /// Selects the speaker (X-Setting-Id).
  public var settingID: String? {
    get { lock.withLock { _settingID } }
    set { lock.withLock { _settingID = newValue } }
  }

  public var isLoggedIn: Bool { lock.withLock { tokens != nil } }

  /// Cheap connectivity probe (the app does the same HEAD on the API base).
  public func reachable() -> Bool {
    var req = URLRequest(url: apiBase, timeoutInterval: 4)
    req.httpMethod = "HEAD"
    do {
      _ = try perform(req, cancel: nil)
      return true
    } catch {
      return false
    }
  }

  // MARK: Auth (Keycloak)

  public func login(username: String, password: String) throws {
    try storeTokens(tokenRequest(["grant_type": "password", "username": username.trimmingCharacters(in: .whitespaces), "password": password]))
  }

  public func logout() {
    lock.withLock {
      tokens = nil
      tokenStore.save(nil)
    }
  }

  // MARK: API

  /// Account configuration; "settings" lists the paired speakers.
  public func config() throws -> JSONObject { try get("configs/multi") as? JSONObject ?? [:] }
  public func speakers() throws -> [JSONObject] { try config().objs("settings") }

  /// Starts a synchronisation; returns the plan: id, fileList, playlistText, time_slot...
  public func createSynchro(type: String = "TRANSFERT") throws -> JSONObject {
    try createSynchro(type: type, setting: nil)
  }

  /// setting: another speaker than the selected one.
  public func createSynchro(type: String, setting: String?) throws -> JSONObject {
    var body = Self.synchroDefaults
    body["status"] = "PENDING"
    body["type"] = type
    body["device_agent"] = Self.userAgent
    guard let plan = try api("POST", "synchros", body, setting: setting) as? JSONObject else { throw BackendError("POST synchros: empty answer") }
    return plan
  }

  public func reportSynchro(id: String, body: JSONObject) throws {
    try reportSynchro(id: id, body: body, setting: nil)
  }

  public func reportSynchro(id: String, body: JSONObject, setting: String?) throws {
    var full = Self.synchroDefaults
    full["device_agent"] = Self.userAgent
    for (k, v) in body where !(v is NSNull) { full[k] = v }
    _ = try api("PUT", "synchros/\(seg(id))", full, setting: setting)
  }

  /// File URLs in a synchro plan are fetched without auth, like the app does.
  public func download(_ url: String, to dest: URL, cancel: CancelToken? = nil) throws {
    try download(url, to: dest, cancel: cancel, progress: nil)
  }

  /// progress: (bytes received, bytes expected or -1), a few times a second.
  public func download(_ url: String, to dest: URL, cancel: CancelToken?, progress: ((Int64, Int64) -> Void)?) throws {
    guard let u = URL(string: Self.lenientURL(url)) else { throw BackendError("download: bad URL \(url)") }
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let req = URLRequest(url: u, timeoutInterval: Self.apiTimeout)
    let (res, tmp) = try performDownload(req, cancel: cancel, progress: progress)
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard (200..<300).contains(res.statusCode) else {
      if res.statusCode == 403, let body = try? String(contentsOf: tmp, encoding: .utf8), body.contains("Key-Pair-Id") {
        throw BackendError("this episode is \(CatalogFormat.lockedMessage)", status: res.statusCode)
      }
      throw BackendError("download \(url) -> HTTP \(res.statusCode)", status: res.statusCode)
    }
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tmp, to: dest)
  }

  // MARK: Catalog
  //
  // The store is a tree of pages: a page has "modules" (keyed by "format":
  // selection_slider, taxon_slider, taxon_grid_large/small,
  // taxon_slider_potatoes, website_purchase). Taxa either open another page
  // ("subpageid") or a taxonomy listing collections/contents.

  public func homePageID() throws -> String? { try config().id("home_page_id") }
  public func page(_ id: String) throws -> JSONObject { try object("pages/\(seg(id))/full") }
  public func taxonomy(_ id: String) throws -> JSONObject { try object("taxonomies/\(seg(id))/full") }
  public func collection(_ id: String) throws -> JSONObject { try object("collections/\(seg(id))/purchase-info") }
  public func content(_ id: String) throws -> JSONObject { try object("contents/\(seg(id))/full") }
  public func search(_ query: String) throws -> [JSONObject] { try list("contents/search/\(seg(query))") }
  public func offeredPacks() throws -> [JSONObject] { try list("packs/list/offered") }
  public func packPreview(_ id: String) throws -> JSONObject { try object("packs/preview/\(seg(id))") }

  /// What is (or will be) on the selected speaker: a tree of folders/contents.
  public func speakerLibrary() throws -> JSONObject { try object("catalogs") }
  public func speakerLibrary(setting: String) throws -> JSONObject { try api("GET", "catalogs", setting: setting) as? JSONObject ?? [:] }

  /// The "basket" of pending changes picked up by the next synchro.
  public func selections() throws -> [JSONObject] { try list("selections") }

  public func selectContents(_ ids: [String], add: Bool) throws -> [JSONObject] {
    asList(try api("POST", "selections", ["add": add, "contents": ids.map(apiID)]))
  }

  // The same, for another speaker than the selected one.
  public func selections(setting: String) throws -> [JSONObject] { asList(try api("GET", "selections", setting: setting)) }

  public func selectContents(_ ids: [String], add: Bool, setting: String) throws -> [JSONObject] {
    asList(try api("POST", "selections", ["add": add, "contents": ids.map(apiID)], setting: setting))
  }

  public func cancelSelections(_ ids: [String], setting: String) throws -> [JSONObject] {
    asList(try api("DELETE", "selections", ["contents": ids.map(apiID)], setting: setting))
  }

  public func selectCollection(_ id: String) throws -> [JSONObject] {
    asList(try api("POST", "selections/collection", ["add": true, "collectionId": apiID(id)]))
  }

  public func cancelSelections(_ ids: [String]) throws -> [JSONObject] {
    asList(try api("DELETE", "selections", ["contents": ids.map(apiID)]))
  }

  public func get(_ path: String) throws -> Any? { try api("GET", path) }

  // MARK: Internals

  private func object(_ path: String) throws -> JSONObject { try get(path) as? JSONObject ?? [:] }
  private func list(_ path: String) throws -> [JSONObject] { asList(try get(path)) }
  private func asList(_ v: Any?) -> [JSONObject] { (v as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }

  /// Ids are numbers in the API; keep them numeric when they are.
  private func apiID(_ id: String) -> Any { Int(id).map { $0 as Any } ?? id }

  private func seg(_ v: String) -> String {
    v.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? v
  }

  private func api(_ verb: String, _ path: String, _ body: JSONObject? = nil, setting: String? = nil, retried: Bool = false) throws -> Any? {
    let token: String? = try lock.withLock {
      if let t = tokens, Int(Date().timeIntervalSince1970) >= t.int("expires_at") { try refresh() }
      return tokens?.str("access_token")
    }
    guard let url = URL(string: path, relativeTo: apiBase)?.absoluteURL else { throw BackendError("bad path \(path)") }
    var req = URLRequest(url: url, timeoutInterval: Self.apiTimeout)
    req.httpMethod = verb
    if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let id = setting ?? settingID { req.setValue(id, forHTTPHeaderField: "X-Setting-Id") }
    if let body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSON.data(body)
    }
    let (res, data) = try perform(req, cancel: nil)

    if res.statusCode == 401, token != nil, !retried {
      try lock.withLock { try refresh() }
      return try api(verb, path, body, setting: setting, retried: true)
    }
    guard (200..<300).contains(res.statusCode) else {
      throw BackendError("\(verb) \(path) -> HTTP \(res.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))", status: res.statusCode)
    }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : try JSON.parse(data)
  }

  private func refresh() throws {
    guard let refreshToken = tokens?.str("refresh_token") else { throw BackendError("not logged in") }
    do {
      try storeTokens(tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken]))
    } catch let e as BackendError where (400..<500).contains(e.status ?? 0) {
      logout()
      throw BackendError("session expired, log in again", status: e.status)
    }
  }

  private func tokenRequest(_ form: [String: String]) throws -> JSONObject {
    var req = URLRequest(url: tokenURL, timeoutInterval: Self.apiTimeout)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var fields = ["client_id": "app"]
    for (k, v) in form { fields[k] = v }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
    req.httpBody = Data(fields.sorted { $0.key < $1.key }.map { k, v in
      "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
    }.joined(separator: "&").utf8)
    let (res, data) = try perform(req, cancel: nil)
    guard (200..<300).contains(res.statusCode) else {
      let detail = ((try? JSON.parse(data)) as? JSONObject)?.str("error_description") ?? String(decoding: data.prefix(200), as: UTF8.self)
      throw BackendError("authentication failed (HTTP \(res.statusCode)): \(detail)", status: res.statusCode)
    }
    guard let raw = try JSON.parse(data) as? JSONObject else { throw BackendError("authentication failed: bad answer") }
    return raw
  }

  private func storeTokens(_ raw: JSONObject) throws {
    guard let access = raw.str("access_token") else { throw BackendError("authentication failed: no access token") }
    let now = Int(Date().timeIntervalSince1970)
    let expiresIn = raw["expires_in"] == nil ? 300 : raw.int("expires_in")
    let t: JSONObject = [
      "access_token": access,
      "refresh_token": raw["refresh_token"] ?? NSNull(),
      "expires_at": now + expiresIn - 30,
      "refresh_expires_at": now + raw.int("refresh_expires_in") - 30,
    ]
    lock.withLock {
      tokens = t
      tokenStore.save(t)
    }
  }

  /// The API hands out URLs with raw spaces / accents (imgproxy URLs
  /// embedding file names). Percent-encode only characters that are never
  /// valid in a URI, leaving existing escapes alone.
  static func lenientURL(_ url: String) -> String {
    let valid = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%".unicodeScalars)
    var out = ""
    for u in url.unicodeScalars {
      if valid.contains(u) { out.unicodeScalars.append(u) } else {
        for b in String(u).utf8 { out += String(format: "%%%02X", b) }
      }
    }
    return out
  }

  // MARK: Transport + HTTP log

  private func logEntry(_ req: URLRequest) -> [String: Any] {
    var headers = Self.appHeaders
    for (k, v) in req.allHTTPHeaderFields ?? [:] { headers[k] = v }
    var request: [String: Any] = [
      "method": req.httpMethod ?? "GET",
      "url": Redact.url(req.url?.absoluteString ?? ""),
      "headers": Redact.headers(headers),
    ]
    if let body = HttpLog.cap(Redact.body(req.httpBody, contentType: req.value(forHTTPHeaderField: "Content-Type"))) {
      request["body"] = body
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return ["id": String(format: "%08x", UInt32.random(in: 0...UInt32.max)), "at": iso.string(from: Date()), "request": request]
  }

  private func responseHeaders(_ res: HTTPURLResponse) -> [String: String] {
    var h: [String: String] = [:]
    for (k, v) in res.allHeaderFields { h[String(describing: k).lowercased()] = String(describing: v) }
    return Redact.headers(h)
  }

  /// Transport failures (DNS, refused/reset connections, timeouts, TLS)
  /// become offline BackendErrors; HTTP statuses are left to the caller.
  private func offline(_ req: URLRequest, _ error: Error) -> Error {
    if error is CancellationError { return error }
    if (error as? URLError)?.code == .cancelled { return CancellationError() }
    let host = req.url?.host ?? "?"
    return BackendError("can't reach \(host) (\(error.localizedDescription)) — is this Mac still on the speaker's Wi-Fi?", offline: true)
  }

  /// Non-HTTP answers (file:// URLs, used to try the app with canned data) count as 200.
  static func http(_ response: URLResponse) -> HTTPURLResponse {
    (response as? HTTPURLResponse)
      ?? HTTPURLResponse(url: response.url ?? apiBase, statusCode: 200, httpVersion: nil,
                         headerFields: ["Content-Type": response.mimeType ?? "application/octet-stream"])!
  }

  private func perform(_ req: URLRequest, cancel: CancelToken?) throws -> (HTTPURLResponse, Data) {
    var entry = logEntry(req)
    let started = monotonic()
    let box = ResultBox<(Data, URLResponse)>()
    let task = session.dataTask(with: req) { data, res, err in
      box.set(err.map { .failure($0) } ?? .success((data ?? Data(), res!)))
    }
    do {
      let (data, response) = try box.wait(task: task, cancel: cancel)
      let res = Self.http(response)
      entry["duration_ms"] = Int(((monotonic() - started) * 1000).rounded())
      var r: [String: Any] = ["status": res.statusCode, "headers": responseHeaders(res)]
      if let b = HttpLog.cap(Redact.body(data, contentType: res.value(forHTTPHeaderField: "Content-Type"))) { r["body"] = b }
      entry["response"] = r
      httpLog?.record(entry)
      return (res, data)
    } catch {
      entry["duration_ms"] = Int(((monotonic() - started) * 1000).rounded())
      entry["error"] = Redact.scrub("\(type(of: error)): \(error.localizedDescription)")
      httpLog?.record(entry)
      throw offline(req, error)
    }
  }

  private func performDownload(_ req: URLRequest, cancel: CancelToken?, progress: ((Int64, Int64) -> Void)?) throws -> (HTTPURLResponse, URL) {
    var entry = logEntry(req)
    let started = monotonic()
    let box = ResultBox<(URL, URLResponse)>()
    let task = session.downloadTask(with: req) { url, res, err in
      if let err { return box.set(.failure(err)) }
      // The temporary file is deleted when this handler returns: keep it.
      let keep = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-dl-\(UUID().uuidString)")
      do {
        try FileManager.default.moveItem(at: url!, to: keep)
        box.set(.success((keep, res!)))
      } catch {
        box.set(.failure(error))
      }
    }
    do {
      let (file, response) = try box.wait(task: task, cancel: cancel) {
        progress?(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
      }
      let res = Self.http(response)
      let type = res.value(forHTTPHeaderField: "Content-Type")
      entry["duration_ms"] = Int(((monotonic() - started) * 1000).rounded())
      var r: [String: Any] = ["status": res.statusCode, "headers": responseHeaders(res)]
      if let b = HttpLog.fileBody(file, contentType: type) { r["body"] = b }
      let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
      r["streamed_bytes"] = size
      entry["response"] = r
      httpLog?.record(entry)
      return (res, file)
    } catch {
      entry["duration_ms"] = Int(((monotonic() - started) * 1000).rounded())
      entry["error"] = Redact.scrub("\(type(of: error)): \(error.localizedDescription)")
      httpLog?.record(entry)
      throw offline(req, error)
    }
  }
}

/// Waits for a URLSession completion handler, cancelling the task when the
/// token is cancelled.
final class ResultBox<T>: @unchecked Sendable {
  private let sem = DispatchSemaphore(value: 0)
  private var result: Result<T, Error>?
  private let lock = NSLock()

  func set(_ r: Result<T, Error>) {
    lock.withLock { result = r }
    sem.signal()
  }

  func wait(task: URLSessionTask, cancel: CancelToken?, tick: (() -> Void)? = nil) throws -> T {
    task.resume()
    while sem.wait(timeout: .now() + 0.2) == .timedOut {
      tick?()
      if cancel?.isCancelled == true {
        task.cancel()
        _ = sem.wait(timeout: .now() + 5)
        throw CancellationError()
      }
    }
    return try lock.withLock { result! }.get()
  }
}
