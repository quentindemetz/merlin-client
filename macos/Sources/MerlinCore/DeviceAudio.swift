import Foundation

/// The library keeps files as they were imported; devices get converted
/// copies when they need one. The speaker needs MP3 at 44.1 kHz and at most
/// 192 kbps (copies are 128k stereo / 64k mono, like Merlin's own files);
/// the iPod needs MP3 (copies are 256k). Copies are cached by track id in
/// cacheDir/<device>/, made again only when the original is newer, and made
/// several at a time.
public struct DeviceAudio {
  public enum Device: String, Sendable { case speaker, ipod }

  public struct Result {
    /// Track id -> the file to send.
    public var files: [String: URL] = [:]
    /// Track id -> why it couldn't be converted.
    public var failed: [String: String] = [:]
    public var converted = 0
  }

  let library: MediaLibrary
  let cacheDir: URL
  let media: MediaTools

  public init(library: MediaLibrary, cacheDir: URL, media: MediaTools = Media()) {
    self.library = library
    self.cacheDir = cacheDir
    self.media = media
  }

  public func needsCopy(_ t: MediaLibrary.Track, for device: Device) -> Bool {
    device == .speaker ? !(t.speakerReady && t.isMP3) : !t.isMP3
  }

  func copyURL(_ t: MediaLibrary.Track, _ device: Device) -> URL {
    cacheDir.appendingPathComponent(device.rawValue).appendingPathComponent("\(t.id).mp3")
  }

  public func files(for tracks: [MediaLibrary.Track], device: Device, cancel: CancelToken? = nil,
                    say: @escaping (String) -> Void = { _ in }) throws -> Result {
    var result = Result()
    var todo: [MediaLibrary.Track] = []
    for t in tracks {
      let original = library.url(t.audio)
      guard FileManager.default.fileExists(atPath: original.path) else { continue }
      if !needsCopy(t, for: device) {
        result.files[t.id] = original
      } else if Self.fresh(copyURL(t, device), than: original) {
        result.files[t.id] = copyURL(t, device)
      } else {
        todo.append(t)
      }
    }
    guard !todo.isEmpty else { return result }

    try FileManager.default.createDirectory(at: cacheDir.appendingPathComponent(device.rawValue), withIntermediateDirectories: true)
    let target = device == .speaker ? "the speaker" : "the iPod"
    say("Converting \(todo.count) file(s) to MP3 for \(target)…")
    let lock = NSLock()
    var done = 0
    var outcomes: [String: Swift.Result<URL, Error>] = [:]
    DispatchQueue.concurrentPerform(iterations: todo.count) { i in
      let t = todo[i]
      let outcome: Swift.Result<URL, Error> = Swift.Result {
        try cancel.check()
        return try convert(t, device)
      }
      lock.withLock {
        outcomes[t.id] = outcome
        done += 1
        if case .success = outcome { say("  converted \(done)/\(todo.count): \(t.title)") }
      }
    }
    for t in todo {
      switch outcomes[t.id] {
      case .success(let url):
        result.files[t.id] = url
        result.converted += 1
      case .failure(let e) where e is CancellationError:
        throw e
      case .failure(let e):
        result.failed[t.id] = e.userMessage
        say("  warning: couldn't convert \(t.title): \(e.userMessage)")
      case nil:
        break
      }
    }
    return result
  }

  /// Cached copies of tracks no longer in the library go.
  public func prune(keeping ids: Set<String>) {
    for device in [Device.speaker, .ipod] {
      let dir = cacheDir.appendingPathComponent(device.rawValue)
      for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
        let id = (name as NSString).deletingPathExtension
        if !ids.contains(id) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
      }
    }
  }

  private func convert(_ t: MediaLibrary.Track, _ device: Device) throws -> URL {
    let src = library.url(t.audio), dest = copyURL(t, device)
    let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(t.id).\(UUID().uuidString).mp3")
    defer { try? FileManager.default.removeItem(at: tmp) }
    switch device {
    case .speaker:
      var info = try media.probe(src)
      if !t.isMP3 { info.codec = "" } // never just copied: the speaker needs MP3
      _ = try media.prepareAudio(src, tmp, info)
    case .ipod:
      try media.encodeMP3(src, tmp, kbps: Media.qualityKbps)
    }
    guard MediaLibrary.size(tmp) > 0 else { throw MerlinError("the conversion produced an empty file") }
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tmp, to: dest)
    return dest
  }

  static func fresh(_ copy: URL, than original: URL) -> Bool {
    guard let c = try? FileManager.default.attributesOfItem(atPath: copy.path),
          (c[.size] as? Int ?? 0) > 0, let cm = c[.modificationDate] as? Date,
          let om = (try? FileManager.default.attributesOfItem(atPath: original.path))?[.modificationDate] as? Date else { return false }
    return cm >= om
  }
}
