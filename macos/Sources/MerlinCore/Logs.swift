import CryptoKit
import Foundation

/// One file per day (`<prefix>YYYY-MM-DD<ext>`), mode 0600, pruned after 14 days.
final class DailyFile: @unchecked Sendable {
  let dir: URL
  private let prefix: String
  private let ext: String
  private let lock = NSLock()

  init(dir: URL, prefix: String, ext: String, keepDays: Int = 14) {
    self.dir = dir
    self.prefix = prefix
    self.ext = ext
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    prune(keepDays)
  }

  static func day(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }

  var url: URL { dir.appendingPathComponent("\(prefix)\(Self.day())\(ext)") }

  func append(_ line: String) {
    lock.withLock {
      let path = url.path
      let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
      guard fd >= 0 else { return }
      defer { close(fd) }
      let bytes = Array((line + "\n").utf8)
      _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
  }

  private func prune(_ keepDays: Int) {
    let cutoff = Self.day(Date().addingTimeInterval(-Double(keepDays) * 86_400))
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
      let day = name.dropFirst(prefix.count).prefix(10)
      if day.count == 10, day < cutoff { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }
  }
}

/// Timestamped trace of the speaker TCP protocol (commands, replies, timings,
/// reconnects), next to the HTTP log. Thread-safe.
public final class SpeakerLog: @unchecked Sendable {
  private let file: DailyFile
  private let echo: ((String) -> Void)?

  public init(dir: URL, echo: ((String) -> Void)? = nil) {
    file = DailyFile(dir: dir, prefix: "speaker-", ext: ".log")
    self.echo = echo
  }

  public var url: URL { file.url }

  public func callAsFunction(_ msg: String) {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss.SSS"
    file.append("\(f.string(from: Date())) \(msg)")
    echo?(msg)
  }
}

// MARK: - Redaction

/// Scrubs secrets and personal data from anything about to be logged.
public enum Redact {
  public static let redacted = "[REDACTED]"

  static func norm(_ key: String) -> String { key.lowercased().filter { $0 != "-" && $0 != "_" } }

  /// Credentials: never logged.
  static let secretNames = [
    "access_token", "refresh_token", "id_token", "token", "password", "pendingPassword", "client_secret",
    "authorization", "proxy-authorization", "cookie", "set-cookie",
  ]
  /// Personal data: the account holder, their home network, names they chose, device identifiers.
  static let piiNames = [
    "username", "email", "mail", "first_name", "last_name", "firstname", "lastname", "phone", "phone_number",
    "address", "street", "zipcode", "zip", "postal_code", "city", "birthdate", "birth_date", "birthday",
    "pendingSsid", "sta_ssid", "speaker_name", "child_name", "mac_address",
  ]
  static let sensitiveKeys = Set((secretNames + piiNames).map(norm))

  /// The same keys inside raw text (truncated / malformed JSON, form bodies),
  /// in any of snake_case, camelCase or kebab-case.
  static let keyAlts: String = (secretNames + piiNames).map { name in
    splitWords(name).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[-_]?")
  }.joined(separator: "|")

  static func splitWords(_ name: String) -> [String] {
    var words: [String] = []
    var current = ""
    for ch in name {
      if ch == "-" || ch == "_" {
        words.append(current); current = ""
      } else if ch.isUppercase {
        words.append(current); current = String(ch)
      } else {
        current.append(ch)
      }
    }
    words.append(current)
    return words.filter { !$0.isEmpty }
  }

  static let jsonPair = regex("(\"(?:\(keyAlts))\"\\s*:\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"?|[^,}\\]\\s]+)", caseless: true)
  static let formPair = regex("(?:^|(?<=[&?\\s]))((?:\(keyAlts))=)[^&\\s]*", caseless: true)
  static let sensitiveParam = regex("token|sig|signature|secret|password|passwd|auth|credential|key|amz", caseless: true)
  static let email = regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
  static let jwt = regex("\\beyJ[\\w-]{4,}\\.[\\w-]{4,}\\.[\\w-]*")
  static let bearer = regex("\\b(Bearer)\\s+\\S+", caseless: true)

  static func regex(_ p: String, caseless: Bool = false) -> NSRegularExpression {
    try! NSRegularExpression(pattern: p, options: caseless ? [.caseInsensitive] : [])
  }

  public static func isSensitive(_ key: String) -> Bool { sensitiveKeys.contains(norm(key)) }

  /// "ssid" is the speaker's own access point in synchro plans (MERLIN_…), but
  /// the user's home network in sta_wifi.json / Wi-Fi settings.
  static func isHomeSSID(_ key: String, _ value: Any?) -> Bool {
    guard norm(key) == "ssid", let s = value as? String else { return false }
    return !s.uppercased().hasPrefix("MERLIN")
  }

  public static func value(_ obj: Any) -> Any {
    switch obj {
    case let dict as [String: Any]:
      var out: [String: Any] = [:]
      for (k, v) in dict {
        out[k] = (isSensitive(k) || isHomeSSID(k, v)) && !(v is NSNull) ? redacted : value(v)
      }
      return out
    case let array as [Any]: return array.map(value)
    case let s as String: return scrub(s)
    default: return obj
    }
  }

  public static func scrub(_ s: String) -> String {
    var out = replace(jsonPair, in: s, with: "$1\"\(redacted)\"")
    out = replace(formPair, in: out, with: "$1\(redacted)")
    out = replace(bearer, in: out, with: "$1 \(redacted)")
    out = replace(jwt, in: out, with: "[JWT]")
    return replace(email, in: out, with: "[EMAIL]")
  }

  static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
    re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                withTemplate: NSRegularExpression.escapedTemplate(for: template)
                                  .replacingOccurrences(of: "\\$1", with: "$1"))
  }

  public static func url(_ raw: String) -> String {
    guard var comps = URLComponents(string: raw) else { return scrub(raw) }
    if let items = comps.queryItems {
      comps.queryItems = items.map { item in
        let hit = isSensitive(item.name) || sensitiveParam.firstMatch(in: item.name, range: NSRange(item.name.startIndex..., in: item.name)) != nil
        return hit ? URLQueryItem(name: item.name, value: redacted) : item
      }
    }
    return scrub(comps.string ?? raw)
  }

  public static func headers(_ headers: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    for (k, v) in headers {
      out[k] = isSensitive(k) ? redacted : k.caseInsensitiveCompare("location") == .orderedSame ? url(v) : scrub(v)
    }
    return out
  }

  /// Parses JSON / form bodies so keys can be redacted; other text is
  /// scrubbed, binary is summarised.
  public static func body(_ raw: Data?, contentType: String?) -> Any? {
    guard let raw, !raw.isEmpty else { return nil }
    let type = contentType?.lowercased() ?? ""
    let text = String(data: raw, encoding: .utf8)
    let trimmed = text?.drop(while: { $0.isWhitespace })
    if type.contains("json") || trimmed?.first == "{" || trimmed?.first == "[" {
      if let parsed = try? JSON.parse(raw) { return value(parsed) }
      return scrub(text ?? String(decoding: raw, as: UTF8.self))
    }
    if type.contains("x-www-form-urlencoded"), let text {
      var form: [String: Any] = [:]
      for pair in text.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
        form[kv[0]] = kv.count > 1 ? kv[1] : ""
      }
      return value(form)
    }
    if let text, !text.contains("\0") { return scrub(text) }
    return "<binary \(raw.count) bytes>"
  }
}

// MARK: - HTTP log

/// Append-only JSON-lines log of every HTTP exchange, one file per day,
/// readable only by the user. Thread-safe.
public final class HttpLog: @unchecked Sendable {
  static let maxBody = 1_000_000 // bytes of (already redacted) JSON per body
  static let textLimit = 256 * 1024 // streamed text bodies (downloads)

  private let file: DailyFile
  private let echo: ((String) -> Void)?

  public init(dir: URL, echo: ((String) -> Void)? = nil) {
    file = DailyFile(dir: dir, prefix: "http-", ext: ".jsonl")
    self.echo = echo
  }

  public var url: URL { file.url }

  public func record(_ entry: [String: Any]) {
    do {
      file.append(try JSON.string(entry))
      echo?(Self.summary(entry))
    } catch {
      echo?("http log write failed: \(error)")
    }
  }

  static func cap(_ body: Any?) -> Any? {
    guard let body, let json = try? JSON.data(body), json.count > maxBody else { return body }
    return ["_truncated": true, "bytes": json.count, "head": String(decoding: json.prefix(maxBody), as: UTF8.self)]
  }

  /// Downloaded files: text/JSON bodies (error pages…) are logged redacted;
  /// binary payloads (MP3/JPG) as a summary that can be checked against the
  /// speaker's SHA-256.
  static func fileBody(_ file: URL, contentType: String?) -> Any? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var sha = SHA256()
    var head = Data()
    var total = 0
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      sha.update(data: chunk)
      if head.count < textLimit { head.append(chunk.prefix(textLimit - head.count)) }
      total += chunk.count
    }
    if total == 0 { return nil }
    if textual(contentType, head) {
      let text = Redact.body(head, contentType: contentType)
      if total > textLimit {
        return ["_truncated": true, "bytes": total, "head": (try? JSON.string(text ?? "")) ?? ""]
      }
      return cap(text)
    }
    return "<binary \(total) bytes, \(contentType ?? "unknown type"), sha256=\(hex(sha.finalize()))>"
  }

  static func textual(_ contentType: String?, _ head: Data) -> Bool {
    if let type = contentType {
      return type.range(of: "^(text/|application/(json|xml|problem|x-www-form-urlencoded|javascript))|\\+json|\\+xml",
                        options: [.regularExpression, .caseInsensitive]) != nil
    }
    guard let sample = String(data: head.prefix(1024), encoding: .utf8) else { return false }
    return !sample.contains("\0")
  }

  static func summary(_ e: [String: Any]) -> String {
    let req = e["request"] as? [String: Any] ?? [:]
    let res = e["response"] as? [String: Any]
    let outcome = (e["error"] as? String) ?? "\(res?["status"] ?? "?")"
    return "\(req["method"] ?? "?") \(req["url"] ?? "?") -> \(outcome) [\(e["duration_ms"] ?? "?")ms]"
  }
}
