import Foundation

/// What fetching protected audio needs from Merlin (tests use a stub).
public protocol PurchaseSource: CatalogSource {
  func speakerLibrary(setting: String) throws -> JSONObject
  func selections(setting: String) throws -> [JSONObject]
  func selectContents(_ ids: [String], add: Bool, setting: String) throws -> [JSONObject]
  func cancelSelections(_ ids: [String], setting: String) throws -> [JSONObject]
  func createSynchro(type: String, setting: String?) throws -> JSONObject
  func reportSynchro(id: String, body: JSONObject, setting: String?) throws
}

extension Backend: PurchaseSource {}

/// An episode to fetch through a speaker: bought or in a subscription,
/// as a speaker library or the catalog lists it.
public struct SpeakerPurchase: Equatable, Sendable {
  public let id: String
  public let title: String
  public let collectionID: String?
  public let size: Int64

  public init(id: String, title: String, collectionID: String?, size: Int64) {
    self.id = id
    self.title = title
    self.collectionID = collectionID
    self.size = size
  }

  /// Every non-free episode in a speaker library tree ("catalogs").
  public static func list(_ library: JSONObject) -> [SpeakerPurchase] {
    var out: [SpeakerPurchase] = []
    var seen = Set<String>()
    func walk(_ nodes: [JSONObject]) {
      for n in nodes {
        if n.str("type") == "CONTENT", let id = n.id("uuid"), (n.str("access_type") ?? "free") != "free", seen.insert(id).inserted {
          out.append(SpeakerPurchase(id: id, title: n.text("title") ?? "Épisode", collectionID: n.id("collection_id"),
                                     size: Int64(n.int("filesize"))))
        }
        walk(n.objs("child"))
      }
    }
    walk(library.objs("treeStructure"))
    return out
  }
}

/// Downloads protected audio (secure.bayard.io), whose catalog link is
/// refused. Merlin only signs those links in the sync plan of a speaker the
/// episode is waiting to be sent to, so this plays the app's part of a sync
/// without the speaker:
///
///   * an episode the speaker doesn't have is added to it, a synchro is
///     started (its plan has the signed link), the file is downloaded, the
///     synchro is reported as aborted and the addition is cancelled;
///   * one the speaker has is first removed (a synchro reported as a success
///     makes Merlin forget it), added again, downloaded, and a second success
///     report says the speaker has it again, which is true.
///
/// Merlin lets a speaker have 120 titles waiting to be sent (measured), and
/// refuses additions that don't fit its free space, so episodes go in
/// batches that adapt to both.
/// Blocking: run it off the main thread.
public final class PurchaseImporter: @unchecked Sendable {
  public struct Speaker: Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  public struct Summary: Equatable {
    public var added = 0
    public var skipped = 0
    public var failed: [String] = []
  }

  /// Titles Merlin lets wait for one speaker's next sync.
  static let titleCap = 120
  static let batchSize = 100
  static let note = "Merlin for Mac: fetched protected audio for its library; the speaker was not contacted"

  private let library: MediaLibrary
  private let source: PurchaseSource
  private let cancel: CancelToken?
  private let say: (String) -> Void
  private let importer: CatalogImporter
  public var onExpect: ((Int64) -> Void)?
  public var onBytes: ((Int64, Int64) -> Void)? {
    didSet { importer.onBytes = onBytes }
  }

  public init(library: MediaLibrary, source: PurchaseSource, cancel: CancelToken? = nil, say: @escaping (String) -> Void = { _ in }) {
    self.library = library
    self.source = source
    self.cancel = cancel
    self.say = say
    importer = CatalogImporter(library: library, source: source, cancel: cancel, say: say)
  }

  /// The speaker's purchases not in the library yet.
  public func missing(setting: String) throws -> [SpeakerPurchase] {
    let have = library.merlinContentIDs()
    return SpeakerPurchase.list(try source.speakerLibrary(setting: setting)).filter { !have.contains($0.id) }
  }

  public func importPurchases(setting: String, speakerName: String) throws -> Summary {
    try fetch(try missing(setting: setting), on: [Speaker(id: setting, name: speakerName)])
  }

  /// Tries the speakers in order; an episode one speaker can't take (its
  /// limits are full) goes to the next.
  public func fetch(_ items: [SpeakerPurchase], on speakers: [Speaker]) throws -> Summary {
    let have = library.merlinContentIDs()
    var seen = Set<String>()
    var todo = items.filter { !have.contains($0.id) && seen.insert($0.id).inserted }
    var summary = Summary()
    guard !todo.isEmpty else { return summary }
    let foldersBefore = Set(library.folders().map(\.id))
    defer { // a collection folder made for episodes that never came
      for f in library.folders() where !foldersBefore.contains(f.id) && library.tracks(in: f.id).isEmpty { try? library.removeFolder(f.id) }
    }
    onExpect?(todo.reduce(0) { $0 + $1.size })

    var problems: [String] = []
    for speaker in speakers where !todo.isEmpty {
      try cancel.check()
      var r = Run()
      do {
        try run(todo, on: speaker, &r)
      } catch let e as CancellationError {
        throw e
      } catch {
        r.problem = error.userMessage
        r.rejected = todo.filter { t in !r.done.contains(t.id) }
        if r.added == 0 && r.skipped == 0 && speakers.count == 1 { throw error }
      }
      summary.added += r.added
      summary.skipped += r.skipped
      summary.failed += r.failed
      todo = r.rejected
      if let p = r.problem { problems.append("\(speaker.name): \(p)") }
    }
    problems.forEach(say)
    if !todo.isEmpty {
      if summary.added == 0 && summary.skipped == 0 && summary.failed.isEmpty {
        throw MerlinError(problems.isEmpty ? "Merlin wouldn't send these episodes" : problems.joined(separator: " — "))
      }
      summary.failed += todo.map { "\($0.title) (\(problems.last ?? "no speaker could take it"))" }
    }
    return summary
  }

  // MARK: One speaker

  private struct Run {
    var added = 0
    var skipped = 0
    var failed: [String] = []
    var rejected: [SpeakerPurchase] = []
    var done = Set<String>()
    var problem: String?
  }

  private enum Mark { case onDevice, pendingAdd, pendingRemoval }

  private func marks(_ speaker: Speaker) throws -> [String: Mark] {
    var out: [String: Mark] = [:]
    for s in try source.selections(setting: speaker.id) {
      guard let id = s.obj("content")?.id("id") else { continue }
      let add = (s["add"] as? Bool) ?? true, pending = (s["selection"] as? Bool) ?? false
      out[id] = add ? (pending ? .pendingAdd : .onDevice) : (pending ? .pendingRemoval : nil)
    }
    return out
  }

  private func run(_ items: [SpeakerPurchase], on speaker: Speaker, _ r: inout Run) throws {
    let state = try marks(speaker)
    let wanted = Set(items.map(\.id))
    let onSpeaker = items.filter { state[$0.id] == .onDevice }
    let others = items.filter { state[$0.id] != .onDevice }

    let room = Self.titleCap - state.values.filter { $0 == .pendingAdd }.count
    let needAdding = others.filter { state[$0.id] != .pendingAdd }
    if !needAdding.isEmpty && room <= 0 {
      r.problem = "already has \(Self.titleCap) episodes waiting for its next sync; sync it first"
      r.rejected += others.filter { state[$0.id] != .pendingAdd }
    }
    var queue = (room <= 0 ? others.filter { state[$0.id] == .pendingAdd } : others).chunks(max(1, min(Self.batchSize, room)))
    while !queue.isEmpty {
      try cancel.check()
      let chunk = queue.removeFirst()
      let toAdd = chunk.filter { state[$0.id] != .pendingAdd }.map(\.id)
      if !toAdd.isEmpty {
        do { _ = try source.selectContents(toAdd, add: true, setting: speaker.id) } catch let e as BackendError {
          if e.status == 409 && chunk.count > 1 { // not enough room for all of them: half at a time
            let half = chunk.count / 2
            queue.insert(contentsOf: [Array(chunk[..<half]), Array(chunk[half...])], at: 0)
            continue
          }
          r.problem = e.userMessage
          r.rejected += chunk
          continue
        }
      }
      defer { if !toAdd.isEmpty { _ = try? source.cancelSelections(toAdd, setting: speaker.id) } }
      try transfer(chunk, speaker, success: false, &r)
    }

    guard !onSpeaker.isEmpty else { return }
    // Removing episodes is reported as a success, which would also "deliver"
    // everything else waiting: park it, and put it back afterwards.
    let now = try marks(speaker)
    guard !now.contains(where: { $0.value == .pendingRemoval && !wanted.contains($0.key) }) else {
      r.problem = "has removals waiting for its next sync; sync it first"
      r.rejected += onSpeaker
      return
    }
    let parked = now.filter { $0.value == .pendingAdd }.map(\.key).sorted()
    for ids in parked.chunks(40) { _ = try source.cancelSelections(ids, setting: speaker.id) }
    defer {
      for ids in parked.chunks(40) {
        do { _ = try source.selectContents(ids, add: true, setting: speaker.id) } catch {
          say("warning: couldn't put \(ids.count) waiting episode(s) back on \(speaker.name): \(error.userMessage)")
        }
      }
    }
    for chunk in onSpeaker.chunks(Self.batchSize) {
      try cancel.check()
      let ids = chunk.map(\.id)
      do {
        _ = try source.selectContents(ids, add: false, setting: speaker.id)
        try closeSynchro(speaker, success: true)
      } catch let e as BackendError {
        _ = try? source.selectContents(ids, add: true, setting: speaker.id)
        r.problem = e.userMessage
        r.rejected += chunk
        continue
      }
      do {
        _ = try source.selectContents(ids, add: true, setting: speaker.id)
      } catch {
        say("warning: \(chunk.count) episode(s) are no longer on \(speaker.name) in Merlin: add them back there (\(error.userMessage))")
        r.problem = error.userMessage
        r.rejected += chunk
        continue
      }
      try transfer(chunk, speaker, success: true, &r)
    }
  }

  /// Starts a synchro for the speaker and ends it: reported as done
  /// (`success`) or as aborted.
  private func closeSynchro(_ speaker: Speaker, success: Bool) throws {
    let plan = try source.createSynchro(type: "TRANSFERT", setting: speaker.id)
    guard let id = plan.id("id") else { throw MerlinError("Merlin's sync plan has no id") }
    report(id, speaker, success: success)
  }

  private func report(_ id: String, _ speaker: Speaker, success: Bool) {
    var body: JSONObject = ["type": "TRANSFERT", "logs": [Self.note]]
    body["status"] = success ? "SUCCESS" : "FAIL"
    body["status_code"] = success ? "100_SUCCEED" : "800_FAILED_ON_USER_ABORT"
    do { try source.reportSynchro(id: id, body: body, setting: speaker.id) } catch {
      say("warning: couldn't close the synchro on Merlin (\(error.userMessage))")
    }
  }

  /// Starts a synchro, downloads these episodes from its plan, ends it.
  private func transfer(_ chunk: [SpeakerPurchase], _ speaker: Speaker, success: Bool, _ r: inout Run) throws {
    say("Asking Merlin for \(chunk.count) episode(s) through \(speaker.name)…")
    let plan = try source.createSynchro(type: "TRANSFERT", setting: speaker.id)
    guard let synchro = plan.id("id") else { throw MerlinError("Merlin's sync plan has no id") }
    defer { report(synchro, speaker, success: success) }

    var links: [String: String] = [:]
    for f in plan.objs("fileList") where f.str("type") == "audio" {
      guard let name = f.str("filename"), let url = f.str("url") else { continue }
      links[(name as NSString).deletingPathExtension] = url
    }
    for p in chunk {
      try cancel.check()
      guard let url = links[p.id] else {
        r.failed.append("\(p.title) (Merlin gave no download link)")
        r.done.insert(p.id)
        continue
      }
      do {
        var c = try source.content(p.id)
        c["audio_url"] = url
        let folder = try p.collectionID.map { try importer.folder(collectionID: $0).id }
        switch try importer.importContent(p.id, json: c, folder: folder, checkLocked: false) {
        case .added: r.added += 1
        case .alreadyThere: r.skipped += 1
        }
        r.done.insert(p.id)
      } catch let e as CancellationError {
        throw e
      } catch let e as BackendError where e.status == 403 && r.added == 0 && r.skipped == 0 {
        throw MerlinError("Merlin refused \(speaker.name)'s download links too (\(e.userMessage))")
      } catch {
        r.failed.append(p.title)
        r.done.insert(p.id)
        say("  \(p.title): \(error.userMessage)")
      }
    }
  }
}

private extension Array {
  func chunks(_ size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
  }
}
