import Foundation

/// Rewrites a synchro plan before it goes to the speaker (Sync calls it
/// right after Merlin answers).
public protocol SpeakerPlanContent {
  func apply(to plan: inout JSONObject, say: (String) -> Void) throws
}

/// The speaker gets the library: Merlin's plan keeps its sections (and
/// their covers) and the favorites node, but everything inside them is
/// replaced by the library's folders, each in the section of the same name
/// (else the first one). The speaker's tree is section -> folder -> track,
/// every node needs a <uuid>.jpg cover and every track a <uuid>.mp3; the
/// 128x128 covers are made in coverDir for each sync.
public struct SpeakerPlaylist: SpeakerPlanContent {
  static let titleBytes = 63 // longest title the server sends; it shortens with "..."

  public struct Summary: Equatable {
    public var folders = 0
    public var tracks = 0
  }

  let library: MediaLibrary
  let target: String
  let coverDir: URL
  let audio: DeviceAudio
  let media: MediaTools
  let cancel: CancelToken?

  /// convertedDir: where converted copies are cached (files that aren't
  /// speaker-ready MP3s).
  public init(library: MediaLibrary, settingID: String, coverDir: URL, convertedDir: URL? = nil,
              media: MediaTools = Media(), cancel: CancelToken? = nil) {
    self.library = library
    target = Self.target(settingID)
    self.coverDir = coverDir
    audio = DeviceAudio(library: library, cacheDir: convertedDir ?? coverDir.deletingLastPathComponent().appendingPathComponent("converted"),
                        media: media)
    self.media = media
    self.cancel = cancel
  }

  public static func target(_ settingID: String) -> String { "speaker:\(settingID)" }

  public func apply(to plan: inout JSONObject, say: (String) -> Void) throws {
    let s = try build(&plan, say: say)
    say("Sending \(s.tracks) episode(s) in \(s.folders) folder(s) from your library")
  }

  @discardableResult
  public func build(_ plan: inout JSONObject, say: (String) -> Void = { _ in }) throws -> Summary {
    guard let text = plan["playlistText"] as? String else { throw MerlinError("plan has no playlistText") }
    guard case .array(let top) = try OrderedJSON.parse(text) else { throw MerlinError("the speaker playlist is not a list") }

    try? FileManager.default.removeItem(at: coverDir)
    try FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)

    // Merlin's containers, emptied.
    var nodes: [OrderedJSON] = []
    var sections: [(key: String, index: Int)] = []
    for n in top where n["child"]?.arrayValue != nil {
      var node = n
      node.set("child", .array([]))
      nodes.append(node)
      let favorite = n["favorite"].map { $0 != .bool(false) && $0 != .null && $0 != .number("0") } ?? false
      if !favorite {
        sections.append((Self.normalized(n["title"]?.stringValue ?? ""), nodes.count - 1))
      }
    }
    let kept = Set(nodes.compactMap { $0["uuid"]?.stringValue })
    var files = plan.objs("fileList").filter { f in
      f.str("type") == "image" && kept.contains(((f.str("filename") ?? "") as NSString).deletingPathExtension)
    }
    if sections.isEmpty {
      let uuid = library.meta("speaker_section_uuid") ?? MediaLibrary.newID()
      library.setMeta("speaker_section_uuid", uuid)
      let title = MediaLibrary.defaultSections[0]
      let cover = coverDir.appendingPathComponent("\(uuid).jpg")
      try media.folderCover(title, cover)
      files.append(file("image", cover, title))
      nodes.insert(.object([("uuid", .from(uuid)), ("title", .from(title)), ("child", .array([]))]), at: 0)
      sections = [(Self.normalized(title), 0)]
    }
    let titles = sections.map { nodes[$0.index]["title"]?.stringValue ?? "" }.filter { !$0.isEmpty }
    if !titles.isEmpty { library.setMeta("speaker_sections", titles.joined(separator: "\n")) }

    let synced = library.syncedFolders(target)
    var messages: [String] = []
    let lock = NSLock()
    let sendable = try audio.files(for: synced.flatMap(\.1), device: .speaker, cancel: cancel) { msg in
      lock.withLock { messages.append(msg) }
    }
    messages.forEach(say)
    audio.prune(keeping: Set(library.allTracks().map(\.id)))

    var summary = Summary()
    for (folder, tracks) in synced {
      let available = tracks.filter { sendable.files[$0.id] != nil }
      guard !available.isEmpty else { continue }
      let index = sections.first { $0.key == Self.normalized(folder.section) }?.index ?? sections[0].index
      let title = Self.title(folder.title)

      let folderCover = coverDir.appendingPathComponent("\(folder.id).jpg")
      if let c = folder.cover, (try? CoverImage.square(library.url(c), to: folderCover)) != nil {
      } else {
        try media.folderCover(title, folderCover) // the speaker shows no names: the cover carries it
      }
      files.append(file("image", folderCover, title))

      var children: [OrderedJSON] = []
      for t in available {
        let cover = coverDir.appendingPathComponent("\(t.id).jpg")
        let made = [t.cover, folder.cover].compactMap { $0 }.contains { (try? CoverImage.square(library.url($0), to: cover)) != nil }
        if !made { try Media.defaultCover(cover) }
        files.append(file("image", cover, t.title))
        var audio = file("audio", sendable.files[t.id]!, t.title)
        audio["filename"] = "\(t.id).mp3"
        files.append(audio)
        children.append(.object([
          ("uuid", .from(t.id)), ("title", .from(Self.title(t.title))), ("add_time", .from(t.addedAt)),
          ("limit_time", .from(0)), ("type", .from("free")),
        ]))
      }
      var kids = nodes[index]["child"]?.arrayValue ?? []
      kids.append(.object([("uuid", .from(folder.id)), ("title", .from(title)), ("child", .array(children))]))
      nodes[index].set("child", .array(kids))
      summary.folders += 1
      summary.tracks += children.count
    }

    plan["playlistText"] = OrderedJSON.array(nodes).serialized
    plan["fileList"] = files
    return summary
  }

  private func file(_ type: String, _ url: URL, _ title: String) -> JSONObject {
    ["type": type, "filename": url.lastPathComponent, "title": title, "path": url.path]
  }

  /// Titles as the speaker gets them from the server: at most 63 bytes,
  /// longer ones shortened to 60 bytes + "...".
  public static func title(_ title: String) -> String {
    let t = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !t.isEmpty else { return "Sans titre" }
    if t.utf8.count <= titleBytes { return t }
    var cut = ""
    for ch in t {
      if cut.utf8.count + String(ch).utf8.count > 60 { break }
      cut.append(ch)
    }
    return cut.trimmingCharacters(in: .whitespaces) + "..."
  }

  /// Section and folder names compare without case or accents.
  public static func normalized(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
