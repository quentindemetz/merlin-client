import CryptoKit
import Foundation
@testable import MerlinCore
import Testing

/// A bucket in memory, with the calls made to it.
final class MemoryStore: ObjectStore, @unchecked Sendable {
  let objects = Locked<[String: Data]>([:])
  let puts = Locked<[String]>([])
  let deletes = Locked<[String]>([])

  func list(prefix: String, cancel: CancelToken?) throws -> [RemoteObject] {
    objects.value.filter { $0.key.hasPrefix(prefix) }.map {
      RemoteObject(key: $0.key, size: Int64($0.value.count), etag: SigV4.hex(Insecure.MD5.hash(data: $0.value)))
    }
  }

  func put(_ file: URL, key: String, md5: Data, contentType: String, cancel: CancelToken?, progress: ((Int64) -> Void)?) throws {
    let data = try Data(contentsOf: file)
    guard Data(Insecure.MD5.hash(data: data)) == md5 else { throw S3Error(status: 400, code: "BadDigest", message: "bad digest") }
    objects.mutate { $0[key] = data }
    puts.mutate { $0.append(key) }
    progress?(Int64(data.count))
  }

  func get(_ key: String, to dest: URL, cancel: CancelToken?, progress: ((Int64) -> Void)?) throws {
    guard let data = objects.value[key] else { throw S3Error(status: 404, code: "NoSuchKey", message: "no such key") }
    try? FileManager.default.removeItem(at: dest)
    try data.write(to: dest)
  }

  func delete(_ key: String, cancel: CancelToken?) throws {
    objects.mutate { $0[key] = nil }
    deletes.mutate { $0.append(key) }
  }
}

@Suite struct SigV4Tests {
  let credentials = AWSCredentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
  let date = Date(timeIntervalSince1970: 1_369_353_600)  // 2013-05-24T00:00:00Z

  /// The GET Object example of the S3 SigV4 documentation.
  @Test func signsLikeTheDocumentation() {
    var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
    req.setValue("bytes=0-9", forHTTPHeaderField: "Range")
    SigV4.sign(&req, credentials: credentials, region: "us-east-1", payloadHash: SigV4.emptyHash, date: date)
    #expect(req.value(forHTTPHeaderField: "Authorization") == """
      AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, \
      SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, \
      Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41
      """)
  }

  /// The GET Bucket (list objects) example: the query is signed too.
  @Test func signsTheQuery() {
    var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!)
    SigV4.sign(&req, credentials: credentials, region: "us-east-1", payloadHash: SigV4.emptyHash, date: date)
    #expect(req.value(forHTTPHeaderField: "Authorization")?.hasSuffix(
      "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
  }

  @Test func buildsURLs() {
    let s3 = S3Client(bucket: "my-backup", region: "eu-west-1", credentials: credentials)
    #expect(s3.url("files/a b.mp3").absoluteString == "https://my-backup.s3.eu-west-1.amazonaws.com/files/a%20b.mp3")
    #expect(s3.url("", query: [("prefix", "files/"), ("list-type", "2")]).absoluteString
      == "https://my-backup.s3.eu-west-1.amazonaws.com/?list-type=2&prefix=files%2F")
    let dotted = S3Client(bucket: "my.backup", region: "eu-west-1", credentials: credentials)
    #expect(dotted.url("x.jpg").absoluteString == "https://s3.eu-west-1.amazonaws.com/my.backup/x.jpg")
  }

  @Test func parsesListings() throws {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name><IsTruncated>true</IsTruncated>
      <Contents><Key>files/a.mp3</Key><Size>42</Size><ETag>&quot;ABCDEF&quot;</ETag></Contents>
      <Contents><Key>files/b.jpg</Key><Size>7</Size><ETag>"0123"</ETag></Contents>
      <NextContinuationToken>tok/en=</NextContinuationToken></ListBucketResult>
      """
    let page = try ListParser.parse(Data(xml.utf8))
    #expect(page.objects == [RemoteObject(key: "files/a.mp3", size: 42, etag: "abcdef"), RemoteObject(key: "files/b.jpg", size: 7, etag: "0123")])
    #expect(page.truncated && page.next == "tok/en=")
  }

  @Test func explainsErrors() {
    let res = HTTPURLResponse(url: URL(string: "https://b.s3.amazonaws.com/")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
    let body = Data("<Error><Code>SignatureDoesNotMatch</Code><Message>long story</Message></Error>".utf8)
    #expect(throws: S3Error.self) { try S3Client.check(res, body) }
    #expect((try? S3Client.check(res, body)) == nil)
    do { try S3Client.check(res, body) } catch { #expect(error.userMessage == "S3: the S3 secret access key is wrong") }
  }
}

@Suite final class BackupTests {
  let dir = tempDir()
  lazy var root = dir.appendingPathComponent("Merlin Library")
  lazy var index = dir.appendingPathComponent("index")
  let store = MemoryStore()
  deinit { try? FileManager.default.removeItem(at: dir) }

  func library() throws -> MediaLibrary {
    let lib = try MediaLibrary(root: root)
    for (i, name) in ["le loup", "la souris", "le chat"].enumerated() {
      let src = dir.appendingPathComponent("\(name).mp3")
      try silentMP3(frames: 10 + i).write(to: src)
      try lib.importFile(src, into: .byAlbum(section: "Musique"), media: TaggedMedia(album: "Comptines", track: i + 1, cover: i == 0))
    }
    return lib
  }

  func backup(prefix: String = "") -> LibraryBackup { LibraryBackup(store: store, prefix: prefix, indexDir: index) }

  @Test func backsUpAndRestores() throws {
    let lib = try library()
    let s = try backup(prefix: "mac/").backUp(lib)
    let files = try MediaLibrary.contents(ofDatabase: root.appendingPathComponent(MediaLibrary.databaseName)).files
    #expect(s.transferred == files.count && s.missing.isEmpty)
    #expect(Set(store.objects.value.keys) == Set(files.map { "mac/files/\($0)" } + ["mac/Library.sqlite", "mac/backup.json"]))
    // The database goes up after the files it refers to.
    #expect(store.puts.value.suffix(2) == ["mac/Library.sqlite", "mac/backup.json"])
    let m = try #require(try backup(prefix: "mac/").manifest())
    #expect(m.libraryID == lib.libraryID && m.tracks == 3 && m.files == files.count)

    let restored = dir.appendingPathComponent("Restored")
    let r = try backup(prefix: "mac/").restore(into: restored)
    #expect(r.transferred == files.count && r.missing.isEmpty)
    let copy = try MediaLibrary(root: restored)
    #expect(copy.libraryID == lib.libraryID)
    #expect(copy.allTracks().map(\.title) == lib.allTracks().map(\.title))
    #expect(copy.missingFiles().isEmpty)
    for f in files { #expect(try Data(contentsOf: restored.appendingPathComponent(f)) == Data(contentsOf: root.appendingPathComponent(f))) }
    // Leaves no scratch files behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: restored.path).allSatisfy { !$0.hasPrefix(".") })
  }

  @Test func sendsOnlyWhatChangedAndPrunes() throws {
    let lib = try library()
    try backup().backUp(lib)
    store.puts.mutate { $0 = [] }

    let again = try backup().backUp(lib)
    #expect(again.transferred == 0 && again.deleted == 0)
    #expect(store.puts.value == ["Library.sqlite", "backup.json"])

    let tracks = lib.allTracks()
    try ID3.setCover(Data("new cover".utf8), in: lib.url(tracks[1].audio), scratch: lib.scratchURL("mp3"))
    try lib.removeTracks([tracks[2].id])
    store.puts.mutate { $0 = [] }
    let s = try backup().backUp(lib)
    #expect(s.transferred == 1 && store.puts.value.first == "files/\(tracks[1].audio)")
    #expect(s.deleted == 1 && store.deletes.value == ["files/\(tracks[2].audio)"])
  }

  @Test func wontOverwriteAnotherLibrarysBackup() throws {
    try backup().backUp(try library())
    let other = try MediaLibrary(root: dir.appendingPathComponent("Other"))
    #expect(throws: LibraryBackup.OtherLibrary.self) { try self.backup().backUp(other) }
    let s = try backup().backUp(other, replacingOtherLibrary: true)
    #expect(s.files == 0 && s.deleted > 0)
    #expect(try backup().manifest()?.libraryID == other.libraryID)
  }

  @Test func resumesAnInterruptedRestore() throws {
    let lib = try library()
    try backup().backUp(lib)
    let restored = dir.appendingPathComponent("Restored")
    try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
    let first = lib.allTracks()[0].audio
    try FileManager.default.copyItem(at: lib.url(first), to: restored.appendingPathComponent(first))
    let r = try backup().restore(into: restored)
    #expect(r.transferred == r.files - 1)
    #expect(throws: MerlinError.self) { try self.backup().restore(into: restored) }
  }

  @Test func reportsAnEmptyBucket() throws {
    #expect(try backup().manifest() == nil)
    #expect(throws: MerlinError.self) { try self.backup().restore(into: self.dir.appendingPathComponent("R")) }
  }
}

/// Against a real bucket, when MERLIN_S3_TEST_BUCKET (and AWS_REGION,
/// AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) are set; uses and then empties
/// the "integration-test/" prefix.
@Suite final class S3IntegrationTests {
  static let env = ProcessInfo.processInfo.environment
  let dir = tempDir()
  deinit { try? FileManager.default.removeItem(at: dir) }

  @Test(.enabled(if: env["MERLIN_S3_TEST_BUCKET"] != nil)) func backsUpAndRestoresThroughS3() throws {
    let e = Self.env
    let s3 = S3Client(bucket: e["MERLIN_S3_TEST_BUCKET"]!, region: e["AWS_REGION"] ?? "eu-west-1",
                      credentials: AWSCredentials(accessKeyID: e["AWS_ACCESS_KEY_ID"]!, secretAccessKey: e["AWS_SECRET_ACCESS_KEY"]!))
    let prefix = "integration-test/"
    defer { for o in (try? s3.list(prefix: prefix, cancel: nil)) ?? [] { try? s3.delete(o.key, cancel: nil) } }
    let lib = try MediaLibrary(root: dir.appendingPathComponent("Library"))
    let src = dir.appendingPathComponent("le loup.mp3")
    try silentMP3(frames: 40).write(to: src)
    try lib.importFile(src, into: .byAlbum(section: "Musique"), media: TaggedMedia(album: "Comptines", cover: true))

    let backup = LibraryBackup(store: s3, prefix: prefix, indexDir: dir.appendingPathComponent("index"))
    let s = try backup.backUp(lib)
    #expect(s.transferred == s.files && s.files >= 2)
    #expect(try backup.backUp(lib).transferred == 0)
    let r = try backup.restore(into: dir.appendingPathComponent("Restored"))
    #expect(r.transferred == s.files && r.missing.isEmpty)
    #expect(try MediaLibrary(root: dir.appendingPathComponent("Restored")).allTracks().count == 1)
  }
}
