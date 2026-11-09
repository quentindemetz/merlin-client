import Foundation
@testable import MerlinCore
import Testing

/// Merlin as seen from one account: each speaker has episodes on it, waiting
/// to be sent, or waiting to be removed; a synchro's plan links the waiting
/// ones; a success report settles everything waiting.
final class StubPurchases: PurchaseSource {
  enum Mark { case onDevice, pendingAdd, pendingRemoval }

  let catalog = StubCatalog()
  var marks: [String: [String: Mark]] = [:]
  var trees: [String: JSONObject] = [:]
  var full: Set<String> = [] // speakers that refuse additions (limits)
  var titleCap = 120 // titles waiting per speaker
  var requestCap = Int.max // titles one request may add (space)
  var refuse = false
  var calls: [String] = []
  private var count = 0

  static func url(_ id: String) -> String { "https://secure.bayard.io/\(id).mp3?Signature=s&Key-Pair-Id=K" }

  func content(_ id: String) throws -> JSONObject { try catalog.content(id) }
  func collection(_ id: String) throws -> JSONObject { try catalog.collection(id) }
  func download(_ url: String, to dest: URL, cancel: CancelToken?, progress: ((Int64, Int64) -> Void)?) throws {
    calls.append("download \(url.split(separator: "?")[0].split(separator: "/").last!)")
    if refuse { throw BackendError("download -> HTTP 403", status: 403) }
    try catalog.download(url, to: dest, cancel: cancel, progress: progress)
  }
  func speakerLibrary(setting: String) throws -> JSONObject { trees[setting] ?? [:] }

  func selections(setting: String) throws -> [JSONObject] {
    (marks[setting] ?? [:]).map { id, m in ["add": m != .pendingRemoval, "selection": m != .onDevice, "content": ["id": id]] }
  }
  func selectContents(_ ids: [String], add: Bool, setting: String) throws -> [JSONObject] {
    calls.append("\(add ? "add" : "remove") \(setting) \(ids.sorted().joined(separator: ","))")
    if add && full.contains(setting) { throw BackendError("HTTP 409 Espace insuffisant", status: 409) }
    if add && ids.count > requestCap { throw BackendError("HTTP 409 Espace insuffisant", status: 409) }
    let waiting = (marks[setting] ?? [:]).values.filter { $0 == .pendingAdd }.count
    if add && waiting + ids.filter({ marks[setting]?[$0] == nil }).count > titleCap {
      throw BackendError("HTTP 409 Limite de titres atteinte", status: 409)
    }
    for id in ids {
      switch (add, marks[setting]?[id]) {
      case (true, nil): marks[setting, default: [:]][id] = .pendingAdd
      case (true, .pendingRemoval?): marks[setting]?[id] = .onDevice
      case (false, .onDevice?): marks[setting]?[id] = .pendingRemoval
      default: break
      }
    }
    return []
  }
  func cancelSelections(_ ids: [String], setting: String) throws -> [JSONObject] {
    calls.append("cancel \(setting) \(ids.sorted().joined(separator: ","))")
    for id in ids where marks[setting]?[id] == .pendingAdd { marks[setting]?[id] = nil }
    return []
  }
  func createSynchro(type: String, setting: String?) throws -> JSONObject {
    count += 1
    calls.append("synchro \(setting ?? "-")")
    let pending = (marks[setting ?? ""] ?? [:]).filter { $0.value == .pendingAdd }.keys.sorted()
    return ["id": "syn\(count)", "fileList": pending.map { ["type": "audio", "filename": "\($0).mp3", "id": $0, "url": Self.url($0)] as JSONObject }]
  }
  func reportSynchro(id: String, body: JSONObject, setting: String?) throws {
    calls.append("report \(body.str("status") ?? "")")
    guard body.str("status") == "SUCCESS", let s = setting else { return }
    for (k, m) in marks[s] ?? [:] {
      if m == .pendingAdd { marks[s]?[k] = .onDevice } else if m == .pendingRemoval { marks[s]?[k] = nil }
    }
  }
}

@Suite final class PurchaseTests {
  let dir = tempDir()
  deinit { try? FileManager.default.removeItem(at: dir) }

  func item(_ id: String) -> SpeakerPurchase { SpeakerPurchase(id: id, title: "Épisode \(id)", collectionID: "art", size: 100) }

  func merlin() -> StubPurchases {
    let m = StubPurchases()
    m.catalog.collections["art"] = ["id": "art", "title": "Le feuilleton d'Artémis", "contents": []]
    for id in (1...9).map({ "a\($0)" }) {
      m.catalog.contents[id] = ["id": id, "title": "Épisode \(id)", "audio_url": "https://secure.bayard.io/\(id).mp3",
                                "collection": ["id": "art", "title": "Le feuilleton d'Artémis"]]
      m.catalog.files[StubPurchases.url(id)] = silentMP3(frames: 12)
    }
    return m
  }

  func library() throws -> MediaLibrary { try MediaLibrary(root: dir.appendingPathComponent("lib")) }
  func speakers(_ ids: String...) -> [PurchaseImporter.Speaker] { ids.map { .init(id: $0, name: $0.capitalized) } }

  @Test func purchasesAreTheSpeakersNonFreeEpisodes() {
    let node = { (id: String, access: String) -> JSONObject in
      ["type": "CONTENT", "uuid": id, "title": "T\(id)", "access_type": access, "collection_id": "art", "filesize": 100]
    }
    let tree: JSONObject = ["treeStructure": [["type": "CATEGORY", "uuid": "h", "child": [
      ["type": "SUBCATEGORY", "uuid": "s", "child": [node("a1", "paid"), node("f1", "free")]], node("m1", "subscriber")]]]]
    #expect(SpeakerPurchase.list(tree).map(\.id) == ["a1", "m1"])
  }

  @Test func anEpisodeTheSpeakerLacksIsAddedFetchedAndTakenBack() throws {
    let lib = try library()
    let m = merlin()
    m.marks["bleue"] = ["x1": .onDevice]
    let s = try PurchaseImporter(library: lib, source: m).fetch([item("a1"), item("a2")], on: speakers("bleue"))
    #expect(s.added == 2 && s.failed.isEmpty)
    #expect(m.marks["bleue"] == ["x1": .onDevice], "the speaker is as it was")
    #expect(m.calls.filter { $0.hasPrefix("report") } == ["report FAIL"], "the synchro is aborted, never a success")
    #expect(m.calls.contains("download a1.mp3") && !m.calls.contains { $0.contains("secure.bayard.io/a1.mp3\"") })
    let folder = try #require(lib.merlinFolder(collection: "art"))
    #expect(Set(lib.tracks(in: folder.id).compactMap(\.sourceID)) == ["a1", "a2"])
  }

  @Test func anEpisodeTheSpeakerHasIsRemovedFetchedAndPutBack() throws {
    let lib = try library()
    let m = merlin()
    m.marks["bleue"] = ["a1": .onDevice, "x9": .pendingAdd, "x1": .onDevice]
    let s = try PurchaseImporter(library: lib, source: m).fetch([item("a1")], on: speakers("bleue"))
    #expect(s.added == 1)
    #expect(m.marks["bleue"] == ["a1": .onDevice, "x9": .pendingAdd, "x1": .onDevice],
            "back on the speaker, and the episode that was waiting is still waiting, not marked as sent")
    #expect(m.calls.filter { $0.hasPrefix("report") } == ["report SUCCESS", "report SUCCESS"])
    #expect(try #require(m.calls.firstIndex(of: "cancel bleue x9")) < (try #require(m.calls.firstIndex(of: "remove bleue a1"))))
    #expect(lib.merlinFolder(collection: "art").map { lib.tracks(in: $0.id).count } == 1)
  }

  @Test func aSpeakerThatIsFullPassesTheEpisodesOn() throws {
    let lib = try library()
    let m = merlin()
    m.full = ["verte"]
    let s = try PurchaseImporter(library: lib, source: m).fetch([item("a1"), item("a2")], on: speakers("verte", "bleue"))
    #expect(s.added == 2)
    #expect(m.marks["verte"]?.isEmpty ?? true)
    #expect(m.marks["bleue"]?.isEmpty ?? true)
  }

  @Test func ifNoSpeakerTakesThemItSaysWhy() throws {
    let lib = try library()
    let m = merlin()
    m.full = ["bleue"]
    #expect { try PurchaseImporter(library: lib, source: m).fetch([item("a1")], on: speakers("bleue")) } throws: {
      "\($0)".contains("Espace insuffisant")
    }
  }

  @Test func refusedLinksStopTheImportAndLeaveTheSpeakerAlone() throws {
    let lib = try library()
    let m = merlin()
    m.refuse = true
    #expect { try PurchaseImporter(library: lib, source: m).fetch([item("a1"), item("a2")], on: speakers("bleue")) } throws: {
      "\($0)".contains("refused Bleue's download links")
    }
    #expect(m.calls.filter { $0.hasPrefix("download") }.count == 1, "stops after the first refusal")
    #expect(m.marks["bleue"]?.isEmpty ?? true)
    #expect(m.calls.last == "cancel bleue a1,a2" || m.calls.contains("cancel bleue a1,a2"))
    #expect(lib.allTracks().isEmpty && lib.merlinFolder(collection: "art") == nil, "no empty folder left")
  }

  @Test func removalsWaitingOnTheSpeakerAreNotSettledBehindTheirBack() throws {
    let lib = try library()
    let m = merlin()
    m.marks["bleue"] = ["a1": .onDevice, "x2": .pendingRemoval]
    #expect(throws: MerlinError.self) { try PurchaseImporter(library: lib, source: m).fetch([item("a1")], on: speakers("bleue")) }
    #expect(m.marks["bleue"] == ["a1": .onDevice, "x2": .pendingRemoval])
    #expect(!m.calls.contains { $0.hasPrefix("report") })
  }

  @Test func bigBatchesAdaptToTheTitleCapAndToFreeSpace() throws {
    let lib = try library()
    let m = merlin()
    m.titleCap = 4
    m.requestCap = 3
    let ids = (1...9).map { "a\($0)" }
    let s = try PurchaseImporter(library: lib, source: m).fetch(ids.map(item), on: speakers("bleue"))
    #expect(s.added == 9 && s.failed.isEmpty)
    #expect(m.marks["bleue"]?.isEmpty ?? true)
    #expect(m.calls.filter { $0.hasPrefix("synchro") }.count >= 3, "several rounds")
  }

  @Test func aSpeakerWithAFullQueueIsLeftAlone() throws {
    let lib = try library()
    let m = merlin()
    let waiting = Dictionary(uniqueKeysWithValues: (1...120).map { ("x\($0)", StubPurchases.Mark.pendingAdd) })
    m.marks["bleue"] = waiting
    #expect { try PurchaseImporter(library: lib, source: m).fetch([item("a1")], on: speakers("bleue")) } throws: {
      "\($0)".contains("waiting for its next sync")
    }
    #expect(m.marks["bleue"] == waiting)
  }
}
