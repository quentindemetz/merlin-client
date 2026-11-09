import Foundation
import MerlinCore
import Observation

/// Downloads from the catalog and file imports, one at a time in the
/// background, in the order they were asked for.
@MainActor @Observable
final class LibraryTasks {
  enum Work {
    /// Episodes, into their collection's folder when it's known.
    case content(id: String, collection: String?)
    case collection(id: String)
    case file(URL, MediaLibrary.ImportDestination)
    /// Rewrites the covers inside these tracks' MP3s; `migration`: the
    /// one-time pass over a library made before covers were embedded.
    case artwork([String], migration: Bool)
    /// The bought episodes on a speaker (from its sync plan).
    case purchases(setting: String, speaker: String)
  }

  /// What a finished job did.
  struct Outcome: Sendable {
    var added = 1
    var transcoded = false
  }

  struct Job: Identifiable {
    let id = UUID()
    let title: String
    let work: Work
    /// Bytes to download (or import), when known; 0 otherwise.
    var expected: Int64 = 0
    /// Catalog id, to badge items being downloaded.
    var catalogID: String? {
      switch work {
      case .content(let id, _), .collection(let id): return id
      case .file, .artwork, .purchases: return nil
      }
    }

    var isArtwork: Bool {
      if case .artwork = work { return true }
      return false
    }

    var isImport: Bool {
      if case .file = work { return true }
      return false
    }
  }

  private(set) var pending: [Job] = []
  private(set) var current: Job?
  private(set) var finished = 0
  private(set) var failures: [String] = []
  private(set) var transcoded = 0
  /// Finished jobs that add to the library (not artwork rewrites).
  private(set) var added = 0
  private(set) var detail: String?

  /// Bytes of the jobs done since the queue started.
  private(set) var bytesDone: Int64 = 0
  /// The current job's bytes so far, and how many it expects.
  private(set) var currentReceived: Int64 = 0
  private(set) var currentExpected: Int64 = 0
  @ObservationIgnored private var started = Date()

  @ObservationIgnored private weak var app: AppModel?
  @ObservationIgnored private var cancel = CancelToken()
  @ObservationIgnored private var running = false

  init(app: AppModel) { self.app = app }

  var isBusy: Bool { current != nil || !pending.isEmpty }
  var total: Int { finished + pending.count + (current == nil ? 0 : 1) }
  /// Imports are counted in files, not bytes (their time is spent
  /// reading tags and covers, not moving bytes).
  var isImporting: Bool { (current?.isImport ?? false) || (current == nil && pending.first?.isImport == true) }

  var bytesReceived: Int64 { bytesDone + currentReceived }
  var bytesTotal: Int64 { bytesDone + max(currentExpected, currentReceived) + pending.reduce(0) { $0 + $1.expected } }
  /// Overall progress by bytes; nil while no size is known.
  var fraction: Double? {
    bytesTotal > 0 ? min(1, Double(bytesReceived) / Double(bytesTotal)) : nil
  }
  /// Average speed since the queue started, in bytes per second.
  var speed: Double {
    let t = Date().timeIntervalSince(started)
    return t > 2 ? Double(bytesReceived) / t : 0
  }

  /// Catalog ids queued or downloading.
  var catalogIDs: Set<String> { Set(([current].compactMap { $0 } + pending).compactMap(\.catalogID)) }

  func add(_ jobs: [Job]) {
    guard !jobs.isEmpty else { return }
    let queued = catalogIDs
    pending += jobs.filter { $0.catalogID == nil || !queued.contains($0.catalogID!) }
    if !running { run() }
  }

  func cancelAll() {
    pending = []
    cancel.cancel()
  }

  private func run() {
    guard let app, let library = app.library else { return }
    running = true
    started = Date()
    cancel = CancelToken()
    let cancel = cancel, backend = app.backend, speakers = app.purchaseSpeakers
    Task {
      while !pending.isEmpty {
        let job = pending.removeFirst()
        current = job
        detail = nil
        currentReceived = 0
        currentExpected = job.expected
        let jobID = job.id
        let result = await Task.detached { () -> Result<Outcome, Error> in
          Result { try Self.perform(job.work, library: library, backend: backend, speakers: speakers, cancel: cancel,
                                    say: { msg in Task { @MainActor in self.detail = msg } },
                                    expect: { n in Task { @MainActor in
                                      if self.current?.id == jobID, n > 0 { self.currentExpected = n }
                                    } },
                                    bytes: { received, end in Task { @MainActor in
                                      guard self.current?.id == jobID else { return }
                                      self.currentReceived = received
                                      self.currentExpected = max(self.currentExpected, end)
                                    } }) }
        }.value
        bytesDone += max(currentExpected, currentReceived)
        currentReceived = 0
        currentExpected = 0
        current = nil
        switch result {
        case .success(let outcome):
          finished += 1
          if !job.isArtwork { added += outcome.added }
          if outcome.transcoded { transcoded += 1 }
        case .failure(let error) where error is CancellationError:
          pending = []
        case .failure(let error):
          finished += 1
          failures.append("\(job.title): \(error.userMessage)")
        }
        app.libraryChanged()
      }
      running = false
      report()
    }
  }

  /// Blocking work, off the main thread.
  nonisolated private static func perform(_ work: Work, library: MediaLibrary, backend: Backend, speakers: [PurchaseImporter.Speaker],
                                          cancel: CancelToken,
                                          say: @escaping (String) -> Void, expect: @escaping (Int64) -> Void,
                                          bytes: @escaping (Int64, Int64) -> Void) throws -> Outcome {
    let importer = CatalogImporter(library: library, source: backend, cancel: cancel, say: say)
    importer.onExpect = expect
    importer.onBytes = bytes
    /// Protected audio comes through a speaker's sync plan.
    func protected(_ items: [SpeakerPurchase]) throws -> PurchaseImporter.Summary {
      let purchases = PurchaseImporter(library: library, source: backend, cancel: cancel, say: say)
      purchases.onExpect = expect
      purchases.onBytes = bytes
      let s = try purchases.fetch(items, on: speakers)
      if !s.failed.isEmpty { throw MerlinError("\(s.added) added, \(s.failed.count) couldn't be downloaded: \(s.failed.prefix(3).joined(separator: ", "))") }
      return s
    }
    switch work {
    case .content(let id, let collection):
      let c = try backend.content(id)
      if CatalogFormat.isLocked(c) {
        _ = try protected([SpeakerPurchase(id: id, title: c.text("title") ?? "Épisode", collectionID: collection ?? c.obj("collection")?.id("id"),
                                           size: CatalogImporter.size(c))])
        return Outcome()
      }
      let folder = try collection.map { try importer.folder(collectionID: $0).id }
      try importer.importContent(id, json: c, folder: folder)
      return Outcome()
    case .collection(let id):
      let s = try importer.importCollection(id)
      if !s.locked.isEmpty { _ = try protected(s.locked) }
      if !s.failed.isEmpty { throw MerlinError("\(s.failed.count) episode(s) couldn't be downloaded: \(s.failed.prefix(3).joined(separator: ", "))") }
      return Outcome()
    case .file(let url, let destination):
      try cancel.check()
      let (_, action) = try library.importFile(url, into: destination)
      return Outcome(transcoded: action == .transcoded)
    case .artwork(let ids, let migration):
      say("Writing covers into \(ids.count) file(s)…")
      try library.embedArtwork(ids, strip: !migration, cancel: cancel)
      if migration { library.markArtworkEmbedded() }
      return Outcome()
    case .purchases(let setting, let speaker):
      let purchases = PurchaseImporter(library: library, source: backend, cancel: cancel, say: say)
      purchases.onExpect = expect
      purchases.onBytes = bytes
      let s = try purchases.importPurchases(setting: setting, speakerName: speaker)
      if !s.failed.isEmpty {
        throw MerlinError("\(s.added) added, \(s.failed.count) couldn't be copied: \(s.failed.prefix(3).joined(separator: ", "))")
      }
      if s.added == 0 { say("\(speaker) has no purchase that isn't in your library already") }
      return Outcome(added: s.added)
    }
  }

  private func report() {
    guard let app else { return }
    let done = added
    var msg = "\(done) item(s) added to the library"
    if transcoded > 0 { msg += " (\(transcoded) converted to MP3)" }
    if !failures.isEmpty {
      msg += "; \(failures.count) failed — \(failures.prefix(2).joined(separator: "; "))"
      app.fail(msg)
    } else if done > 0 {
      app.notify(msg)
    }
    finished = 0
    bytesDone = 0
    added = 0
    transcoded = 0
    failures = []
  }
}
