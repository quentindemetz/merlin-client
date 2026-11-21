import Foundation

/// Rewrites a synchro plan before it goes to the speaker (Sync calls it
/// right after Merlin answers).
public protocol SpeakerPlanContent {
  func apply(to plan: inout JSONObject, say: (String) -> Void) throws
}

/// The speaker gets the library: Merlin's plan keeps its sections (and
/// their covers), the favorites node and the "recently added" node, but
/// everything inside them is replaced by the library's folders, each in the
/// section of the same name. Merlin only sends the sections the account has
/// content in, so a missing known section (a default one, or one the
/// speaker had before) is created; any other name goes to the first
/// section. The speaker's tree is section -> folder -> track, except
/// "Dernier ajouts", a flat list of the newest tracks (same uuids as in
/// their folders). Every node needs a <uuid>.jpg cover and every track a
/// <uuid>.mp3; the 128x128 covers are made in coverDir for each sync.
public struct SpeakerPlaylist: SpeakerPlanContent {
  static let titleBytes = 63 // longest title the server sends; it shortens with "..."
  /// How many tracks "Dernier ajouts" lists.
  static let recentCount = 20

  /// Merlin's own sections, as its server sends them (same uuids in every
  /// plan), by normalized title. Their 128x128 covers, as served by Merlin,
  /// ship with the app: Resources/SectionCovers/<key>.jpg.
  static let merlinSections: [String: String] = [
    "histoires": "8a251a87-9533-4638-81e0-2b2c911c4a98",
    "musique": "fd32185b-e8bb-463c-8198-0a6c4eb4b954",
    "documentaires": "4966cf91-8698-4a5a-be3d-094566e66301",
  ]

  /// The official cover of one of Merlin's sections, from the app's resources.
  static func bundledCover(_ key: String) -> URL? {
    resourceBundle?.url(forResource: key, withExtension: "jpg", subdirectory: "SectionCovers")
  }

  /// MerlinCore's resource bundle, wherever it was put: in the .app's
  /// Resources (build-app.sh), or next to the binary / test bundle (swift
  /// build). Not Bundle.module, which crashes when the bundle is missing.
  private static let resourceBundle: Bundle? = {
    let name = "Merlin_MerlinCore.bundle"
    let here = Bundle(for: ResourceToken.self)
    let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                  here.resourceURL, here.bundleURL.deletingLastPathComponent()]
    return places.compactMap { $0?.appendingPathComponent(name) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
      .flatMap(Bundle.init(url:))
  }()

  private final class ResourceToken {}

  /// The server's "recently added" node: tracks, not a section.
  public static func isRecent(_ title: String) -> Bool {
    ["dernier ajouts", "derniers ajouts", "dernier ajout", "derniers ajout"].contains(normalized(title))
  }

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

    // Merlin's containers, emptied: sections first, then the special nodes.
    var sectionNodes: [OrderedJSON] = [], special: [OrderedJSON] = []
    var recentIndex: Int? // in special
    for n in top where n["child"]?.arrayValue != nil {
      var node = n
      node.set("child", .array([]))
      let favorite = n["favorite"].map { $0 != .bool(false) && $0 != .null && $0 != .number("0") } ?? false
      if favorite || Self.isRecent(n["title"]?.stringValue ?? "") {
        if !favorite { recentIndex = special.count }
        special.append(node)
      } else {
        sectionNodes.append(node)
      }
    }
    let kept = Set((sectionNodes + special).compactMap { $0["uuid"]?.stringValue })
    var files = plan.objs("fileList").filter { f in
      f.str("type") == "image" && kept.contains(((f.str("filename") ?? "") as NSString).deletingPathExtension)
    }
    // Remember Merlin's sections (uuid and cover) for plans that leave them out.
    for n in sectionNodes {
      guard let uuid = n["uuid"]?.stringValue, let title = n["title"]?.stringValue,
            let url = files.first(where: { ($0.str("filename") as NSString?)?.deletingPathExtension == uuid })?.str("url"),
            let data = try? JSON.data(["uuid": uuid, "cover": url]) else { continue }
      library.setMeta("speaker_section.\(Self.normalized(title))", String(decoding: data, as: UTF8.self))
    }
    // Sections the speaker can get even if Merlin didn't send them.
    let known = Set((MediaLibrary.defaultSections + (library.meta("speaker_sections") ?? "").split(separator: "\n").map(String.init))
      .filter { !Self.isRecent($0) }.map(Self.normalized))
    func sectionIndex(_ name: String) -> Int? {
      sectionNodes.firstIndex { Self.normalized($0["title"]?.stringValue ?? "") == Self.normalized(name) }
    }
    func addSection(_ title: String) throws -> Int {
      let key = Self.normalized(title)
      // As Merlin last sent it (uuid + cover URL), else one of its own
      // sections (uuid + bundled cover), else ours.
      let seen = library.meta("speaker_section.\(key)").flatMap { try? JSON.parse(Data($0.utf8)) as? JSONObject }
      let seenUUID = seen?.str("uuid"), seenURL = seen?.str("cover")
      let uuid: String
      if let id = seenUUID ?? Self.merlinSections[key] {
        uuid = id
      } else {
        let legacy = key == Self.normalized(MediaLibrary.defaultSections[0]) ? library.meta("speaker_section_uuid") : nil
        uuid = library.meta("speaker_section_uuid.\(key)") ?? legacy ?? MediaLibrary.newID()
        library.setMeta("speaker_section_uuid.\(key)", uuid)
      }
      let cover = coverDir.appendingPathComponent("\(uuid).jpg")
      if let bundled = Self.bundledCover(key) {
        try FileManager.default.copyItem(at: bundled, to: cover)
      } else {
        try media.folderCover(title, cover)
      }
      // Merlin's own sections: the shipped covers, made for the speaker's
      // screen (Merlin's JPEGs speckle on it). Others: the latest cover
      // Merlin sent; the one above if it can't be downloaded.
      if let seenURL, Self.bundledCover(key) == nil {
        files.append(["type": "image", "filename": "\(uuid).jpg", "title": title, "url": seenURL, "fallbackPath": cover.path])
      } else {
        files.append(file("image", cover, title))
      }
      sectionNodes.append(.object([("uuid", .from(uuid)), ("title", .from(title)), ("child", .array([]))]))
      return sectionNodes.count - 1
    }

    let synced = library.syncedFolders(target)
    var messages: [String] = []
    let lock = NSLock()
    let sendable = try audio.files(for: synced.flatMap(\.1), device: .speaker, cancel: cancel) { msg in
      lock.withLock { messages.append(msg) }
    }
    messages.forEach(say)
    audio.prune(keeping: Set(library.allTracks().map(\.id)))

    var summary = Summary()
    var recent: [(Int, OrderedJSON)] = []
    for (folder, tracks) in synced {
      let available = tracks.filter { sendable.files[$0.id] != nil }
      guard !available.isEmpty else { continue }
      let index: Int
      if let i = sectionIndex(folder.section) {
        index = i
      } else if known.contains(Self.normalized(folder.section)) || sectionNodes.isEmpty {
        index = try addSection(known.contains(Self.normalized(folder.section)) ? folder.section : MediaLibrary.defaultSections[0])
      } else {
        index = 0
      }
      let title = Self.title(folder.title)

      let folderCover = coverDir.appendingPathComponent("\(folder.id).jpg")
      if let c = folder.cover, (try? CoverImage.square(library.url(c), to: folderCover)) != nil {
      } else {
        try media.folderCover(title, folderCover) // the speaker shows no names: the cover carries it
      }
      files.append(file("image", folderCover, title))

      var children: [OrderedJSON] = []
      let covers = try available.map { t -> URL in
        let cover = coverDir.appendingPathComponent("\(t.id).jpg")
        let made = [t.cover, folder.cover].compactMap { $0 }.contains { (try? CoverImage.square(library.url($0), to: cover)) != nil }
        if !made { try Media.defaultCover(cover) }
        return cover
      }
      // The speaker shows no titles: an album whose tracks all share one
      // picture gets the track numbers drawn on it.
      if covers.count > 1, covers.dropFirst().allSatisfy({ CoverImage.looksSame(covers[0], $0) }) {
        for (n, cover) in zip(Self.trackNumbers(available), covers) { try CoverImage.addNumber(n, to: cover) }
      }
      for t in available {
        let cover = coverDir.appendingPathComponent("\(t.id).jpg")
        files.append(file("image", cover, t.title))
        var audio = file("audio", sendable.files[t.id]!, t.title)
        audio["filename"] = "\(t.id).mp3"
        files.append(audio)
        let node = OrderedJSON.object([
          ("uuid", .from(t.id)), ("title", .from(Self.title(t.title))), ("add_time", .from(t.addedAt)),
          ("limit_time", .from(0)), ("type", .from("free")),
        ])
        children.append(node)
        recent.append((t.addedAt, node))
      }
      var kids = sectionNodes[index]["child"]?.arrayValue ?? []
      kids.append(.object([("uuid", .from(folder.id)), ("title", .from(title)), ("child", .array(children))]))
      sectionNodes[index].set("child", .array(kids))
      summary.folders += 1
      summary.tracks += children.count
    }
    if let recentIndex { // newest first; stable for tracks added together
      let newest = recent.enumerated().sorted { ($0.element.0, -$0.offset) > ($1.element.0, -$1.offset) }
        .prefix(Self.recentCount).map(\.element.1)
      special[recentIndex].set("child", .array(Array(newest)))
    }

    let titles = sectionNodes.compactMap { $0["title"]?.stringValue }.filter { !$0.isEmpty }
    if !titles.isEmpty { library.setMeta("speaker_sections", titles.joined(separator: "\n")) }

    plan["playlistText"] = OrderedJSON.array(sectionNodes + special).serialized
    plan["fileList"] = files
    return summary
  }

  private func file(_ type: String, _ url: URL, _ title: String) -> JSONObject {
    ["type": type, "filename": url.lastPathComponent, "title": title, "path": url.path]
  }

  /// The tags' track numbers when every track has its own, else 1, 2, 3...
  /// in the folder's order.
  static func trackNumbers(_ tracks: [MediaLibrary.Track]) -> [Int] {
    let tagged = tracks.compactMap(\.episode)
    if tagged.count == tracks.count, Set(tagged).count == tagged.count, tagged.allSatisfy({ $0 > 0 }) { return tagged }
    return Array(1...tracks.count)
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
