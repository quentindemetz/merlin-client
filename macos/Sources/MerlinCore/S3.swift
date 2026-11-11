import CryptoKit
import Foundation

/// An object in a bucket, as listed.
public struct RemoteObject: Sendable, Equatable {
  public var key: String
  public var size: Int64
  /// The MD5 of the content, in hex (single-part uploads, which are the only
  /// kind this app makes).
  public var etag: String

  public init(key: String, size: Int64, etag: String) {
    self.key = key
    self.size = size
    self.etag = etag
  }
}

/// Where backups go: S3, or a fake in the tests. Blocking calls.
public protocol ObjectStore: Sendable {
  func list(prefix: String, cancel: CancelToken?) throws -> [RemoteObject]
  /// Uploads a file; `md5` is checked by the store.
  func put(_ file: URL, key: String, md5: Data, contentType: String, cancel: CancelToken?, progress: ((Int64) -> Void)?) throws
  /// Downloads to dest (replaced). Throws `S3Error` with status 404 when missing.
  func get(_ key: String, to dest: URL, cancel: CancelToken?, progress: ((Int64) -> Void)?) throws
  func delete(_ key: String, cancel: CancelToken?) throws
}

public struct S3Error: LocalizedError, CustomStringConvertible {
  public let status: Int
  public let code: String
  public let message: String

  public init(status: Int, code: String, message: String) {
    self.status = status
    self.code = code
    self.message = message
  }

  public var isNotFound: Bool { status == 404 }
  public var errorDescription: String? { message }
  public var description: String { message }
}

public struct AWSCredentials: Sendable, Equatable {
  public var accessKeyID: String
  public var secretAccessKey: String

  public init(accessKeyID: String, secretAccessKey: String) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
  }
}

/// AWS Signature Version 4, for S3.
public enum SigV4 {
  /// Adds x-amz-date and Authorization to req, signing host and every header
  /// already set. `payloadHash` must also be sent as x-amz-content-sha256.
  public static func sign(_ req: inout URLRequest, credentials: AWSCredentials, region: String, payloadHash: String, date: Date = Date()) {
    let stamp = timestamp(date)
    let day = String(stamp.prefix(8))
    req.setValue(stamp, forHTTPHeaderField: "x-amz-date")
    req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    let url = req.url!
    var headers: [String: String] = [:]
    for (k, v) in req.allHTTPHeaderFields ?? [:] {
      headers[k.lowercased()] = v.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
    headers["host"] = url.port.map { "\(url.host!):\($0)" } ?? url.host!
    let names = headers.keys.sorted()
    let signed = names.joined(separator: ";")
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
    let canonical = [
      req.httpMethod ?? "GET",
      path.isEmpty ? "/" : path,
      canonicalQuery(url),
      names.map { "\($0):\(headers[$0]!)\n" }.joined(),
      signed,
      payloadHash,
    ].joined(separator: "\n")
    let scope = "\(day)/\(region)/s3/aws4_request"
    let toSign = ["AWS4-HMAC-SHA256", stamp, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
    var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
    for part in [day, region, "s3", "aws4_request"] {
      key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
    }
    let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
    req.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signed), Signature=\(signature)",
                 forHTTPHeaderField: "Authorization")
  }

  static func timestamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: date)
  }

  /// The query as sent: we always build it already encoded and sorted.
  static func canonicalQuery(_ url: URL) -> String {
    guard let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, !q.isEmpty else { return "" }
    return q.split(separator: "&").map { pair -> String in
      pair.contains("=") ? String(pair) : "\(pair)="
    }.sorted().joined(separator: "&")
  }

  /// RFC 3986 encoding, as SigV4 wants it ("/" kept in paths).
  public static func encode(_ s: String, keepSlash: Bool = false) -> String {
    var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    if keepSlash { allowed.insert("/") }
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
  }

  public static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public static let emptyHash = hex(SHA256.hash(data: Data()))
}

/// A bucket on Amazon S3. Requests are signed with SigV4; uploads stream
/// from disk with an unsigned payload, protected by Content-MD5.
public final class S3Client: ObjectStore, @unchecked Sendable {
  public let bucket: String
  public let region: String
  private let credentials: AWSCredentials
  private let session: URLSession
  private let endpoint: URL?

  /// endpoint: another S3-compatible server (path-style), for tests.
  public init(bucket: String, region: String, credentials: AWSCredentials, endpoint: URL? = nil) {
    self.bucket = bucket
    self.region = region
    self.credentials = credentials
    self.endpoint = endpoint
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 6 * 3600
    session = URLSession(configuration: config)
  }

  /// Virtual-hosted URLs, or path-style for dotted bucket names (whose
  /// virtual host doesn't match AWS's TLS certificate).
  func url(_ key: String, query: [(String, String)] = []) -> URL {
    var c = URLComponents()
    c.scheme = endpoint?.scheme ?? "https"
    let path = SigV4.encode(key, keepSlash: true)
    if let endpoint {
      c.host = endpoint.host
      c.port = endpoint.port
      c.percentEncodedPath = "/\(bucket)/\(path)"
    } else if bucket.contains(".") {
      c.host = "s3.\(region).amazonaws.com"
      c.percentEncodedPath = "/\(bucket)/\(path)"
    } else {
      c.host = "\(bucket).s3.\(region).amazonaws.com"
      c.percentEncodedPath = "/\(path)"
    }
    if !query.isEmpty {
      c.percentEncodedQuery = query.map { "\(SigV4.encode($0.0))=\(SigV4.encode($0.1))" }.sorted().joined(separator: "&")
    }
    return c.url!
  }

  private func request(_ method: String, _ key: String, query: [(String, String)] = [], headers: [String: String] = [:],
                       payloadHash: String = SigV4.emptyHash) -> URLRequest {
    var req = URLRequest(url: url(key, query: query))
    req.httpMethod = method
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    SigV4.sign(&req, credentials: credentials, region: region, payloadHash: payloadHash)
    return req
  }

  public func list(prefix: String, cancel: CancelToken?) throws -> [RemoteObject] {
    var all: [RemoteObject] = []
    var token: String?
    repeat {
      var q = [("list-type", "2"), ("prefix", prefix)]
      if let token { q.append(("continuation-token", token)) }
      let data = try retrying(cancel) { try self.send(self.request("GET", "", query: q), cancel: cancel) }
      let page = try ListParser.parse(data)
      all += page.objects
      token = page.truncated ? page.next : nil
    } while token != nil
    return all
  }

  public func put(_ file: URL, key: String, md5: Data, contentType: String, cancel: CancelToken?, progress: ((Int64) -> Void)?) throws {
    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
    guard size < 5 << 30 else { throw MerlinError("\(file.lastPathComponent) is over 5 GB, too big for a single upload") }
    try retrying(cancel) {
      let req = self.request("PUT", key, headers: ["Content-MD5": md5.base64EncodedString(), "Content-Type": contentType],
                             payloadHash: "UNSIGNED-PAYLOAD")
      let box = ResultBox<(Data, URLResponse)>()
      let task = self.session.uploadTask(with: req, fromFile: file) { data, res, err in
        box.set(err.map { .failure($0) } ?? .success((data ?? Data(), res!)))
      }
      let (data, res) = try self.wait(box, task, cancel) { progress?(task.countOfBytesSent) }
      try Self.check(res, data)
    }
  }

  public func get(_ key: String, to dest: URL, cancel: CancelToken?, progress: ((Int64) -> Void)?) throws {
    try retrying(cancel) {
      let box = ResultBox<(URL, URLResponse)>()
      let task = self.session.downloadTask(with: self.request("GET", key)) { url, res, err in
        if let err { return box.set(.failure(err)) }
        // The temporary file is deleted when this handler returns: keep it.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-s3-\(UUID().uuidString)")
        do {
          try FileManager.default.moveItem(at: url!, to: keep)
          box.set(.success((keep, res!)))
        } catch {
          box.set(.failure(error))
        }
      }
      let (file, res) = try self.wait(box, task, cancel) { progress?(task.countOfBytesReceived) }
      if (res as? HTTPURLResponse)?.statusCode != 200 {
        let body = (try? Data(contentsOf: file)) ?? Data()
        try? FileManager.default.removeItem(at: file)
        try Self.check(res, body)
      }
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.moveItem(at: file, to: dest)
    }
  }

  public func delete(_ key: String, cancel: CancelToken?) throws {
    _ = try retrying(cancel) { try self.send(self.request("DELETE", key), cancel: cancel) }
  }

  // MARK: Plumbing

  private func send(_ req: URLRequest, cancel: CancelToken?) throws -> Data {
    let box = ResultBox<(Data, URLResponse)>()
    let task = session.dataTask(with: req) { data, res, err in
      box.set(err.map { .failure($0) } ?? .success((data ?? Data(), res!)))
    }
    let (data, res) = try wait(box, task, cancel)
    try Self.check(res, data)
    return data
  }

  private func wait<T>(_ box: ResultBox<T>, _ task: URLSessionTask, _ cancel: CancelToken?, tick: (() -> Void)? = nil) throws -> T {
    do {
      return try box.wait(task: task, cancel: cancel, tick: tick)
    } catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      throw Transient(message: "can't reach S3 (\(error.localizedDescription))")
    }
  }

  /// A network failure or a 5xx: worth trying again.
  struct Transient: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// Three tries, a few seconds apart, for network failures and 5xx answers.
  private func retrying<T>(_ cancel: CancelToken?, _ body: () throws -> T) throws -> T {
    var attempt = 0
    while true {
      do {
        return try body()
      } catch let error where attempt < 2 && (error is Transient || ((error as? S3Error)?.status ?? 0) >= 500) {
        attempt += 1
        try cancel.sleep(Double(attempt) * 3)
      }
    }
  }

  static func check(_ response: URLResponse, _ body: Data) throws {
    guard let res = response as? HTTPURLResponse, !(200..<300).contains(res.statusCode) else { return }
    let fields = ErrorParser.parse(body)
    let code = fields["Code"] ?? "HTTP \(res.statusCode)"
    var message = fields["Message"] ?? HTTPURLResponse.localizedString(forStatusCode: res.statusCode)
    switch code {
    case "InvalidAccessKeyId": message = "S3 doesn't know this access key ID"
    case "SignatureDoesNotMatch": message = "the S3 secret access key is wrong"
    case "NoSuchBucket": message = "the bucket doesn't exist"
    case "AccessDenied": message = "S3 refused access (check the access key's permissions on the bucket)"
    case "PermanentRedirect", "AuthorizationHeaderMalformed":
      if let region = res.value(forHTTPHeaderField: "x-amz-bucket-region") ?? fields["Region"] {
        message = "the bucket is in region \(region)"
      }
    default: break
    }
    throw S3Error(status: res.statusCode, code: code, message: "S3: \(message)")
  }
}

/// ListObjectsV2 answers.
enum ListParser {
  struct Page {
    var objects: [RemoteObject] = []
    var truncated = false
    var next: String?
  }

  static func parse(_ data: Data) throws -> Page {
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { throw MerlinError("S3: unreadable bucket listing") }
    return delegate.page
  }

  private final class Delegate: NSObject, XMLParserDelegate {
    var page = Page()
    private var text = ""
    private var current: RemoteObject?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
      text = ""
      if name == "Contents" { current = RemoteObject(key: "", size: 0, etag: "") }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
      switch name {
      case "Key": current?.key = text
      case "Size": current?.size = Int64(text) ?? 0
      case "ETag": current?.etag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
      case "Contents": if let c = current { page.objects.append(c) }; current = nil
      case "IsTruncated": page.truncated = text == "true"
      case "NextContinuationToken": page.next = text
      default: break
      }
    }
  }
}

/// S3 error documents: <Error><Code>…</Code><Message>…</Message>…</Error>.
enum ErrorParser {
  static func parse(_ data: Data) -> [String: String] {
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    _ = parser.parse()
    return delegate.fields
  }

  private final class Delegate: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { text = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { fields[name] = text }
  }
}
