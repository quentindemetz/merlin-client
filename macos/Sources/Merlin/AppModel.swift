import AppKit
import MerlinCore
import Observation
import SwiftUI

/// SwiftUI's `@State`, without its macro (the Command Line Tools don't ship
/// the SwiftUIMacros plugin; the plain property wrapper works the same).
typealias ViewState = SwiftUI.State

enum SidebarItem: String, Hashable {
  case library, catalog, search, sync, ipod
}

struct StatusMessage: Equatable {
  enum Kind { case ok, error, busy }
  let kind: Kind
  let text: String
  let id = UUID()
}

/// Shared state of the app: the library, account, selected speaker, status
/// line, and the downloads, syncs and iPod copies in progress. Blocking core calls run off the main thread
/// through `perform`.
@MainActor @Observable
final class AppModel {
  let config = Config()
  let backend: Backend
  let speakerLog: SpeakerLog
  let network = MacNetwork()
  @ObservationIgnored let location = LocationPermission()

  var loggedIn: Bool
  var speakers: [Speaker] = []
  var settingID: String?
  var status: StatusMessage?
  var locationStatus: LocationPermission.Status = .undetermined

  /// The sidebar section, restored at the next launch.
  var section: SidebarItem? = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .library {
    didSet { UserDefaults.standard.set(section?.rawValue, forKey: "section") }
  }
  var catalogPath: [CatalogRoute] = []
  var searchPath: [CatalogRoute] = []
  var searchText = ""
  var searchQuery = ""
  /// Bumped to put the cursor in the search field (⌘F).
  var searchFocusRequest = 0

  /// Bumped when the speaker selection changes, so catalog lists reload.
  var contentVersion = 0

  /// The library, in the folder chosen in Library › Choose Library Folder.
  private(set) var library: MediaLibrary?
  private(set) var libraryError: String?
  /// Bumped when the library changes, so views reload.
  private(set) var libraryVersion = 0
  /// Merlin content ids already in the library (for the catalog's badges).
  private(set) var inLibrary: Set<String> = []
  /// Merlin collection id -> episodes of it in the library.
  private(set) var collectionsInLibrary: [String: Int] = [:]
  @ObservationIgnored private(set) var tasks: LibraryTasks!
  @ObservationIgnored private(set) var backup: BackupModel!
  let player = Player()

  static let libraryPathKey = "libraryPath"
  static var defaultLibraryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Merlin Library", isDirectory: true)
  }

  var syncSession: SyncSession?

  /// iPods mounted in disk mode, and the copy in progress.
  var ipods: [IPodDevice] = []
  var ipodSession: IPodSession?
  /// Bumped when an iPod's content changed.
  var ipodVersion = 0
  @ObservationIgnored private var mountObservers: [NSObjectProtocol] = []
  /// The traffic filter, shared by every sync so the admin password is asked
  /// at most once per app session.
  @ObservationIgnored private(set) lazy var isolation = Isolation(statePath: config.isolationStateURL)

  struct Speaker: Identifiable, Hashable {
    let id: String
    let name: String
    let toSync: Int
  }

  init() {
    let log = HttpLog(dir: config.logDir)
    // $MERLIN_API_BASE / $MERLIN_TOKEN_URL point the app at another server (e.g. a local mock).
    let env = ProcessInfo.processInfo.environment
    backend = Backend(tokenStore: config.tokenStore, settingID: config.settingID, httpLog: log,
                      apiBase: env["MERLIN_API_BASE"].flatMap(URL.init(string:)) ?? Backend.apiBase,
                      tokenURL: env["MERLIN_TOKEN_URL"].flatMap(URL.init(string:)) ?? Backend.tokenURL)
    speakerLog = SpeakerLog(dir: config.logDir)
    loggedIn = backend.isLoggedIn
    settingID = config.settingID
    locationStatus = location.status
    tasks = LibraryTasks(app: self)
    backup = BackupModel(app: self)
    let path = UserDefaults.standard.string(forKey: Self.libraryPathKey)
    openLibrary(at: path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultLibraryURL, remember: false)
    location.onChange = { [weak self] in self?.locationStatus = $0 }
    ipods = IPodDevice.connected()
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
      mountObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshIPods() }
      })
    }
  }

  /// Speakers to fetch protected audio through, the selected one first.
  var purchaseSpeakers: [PurchaseImporter.Speaker] {
    speakers.sorted { ($0.id == settingID ? 0 : 1) < ($1.id == settingID ? 0 : 1) }.map { .init(id: $0.id, name: $0.name) }
  }

  var currentSpeaker: Speaker? { speakers.first { $0.id == settingID } }

  // MARK: Startup

  func start() async {
    // Ask for Location Services up front (so the dialog shows while the user
    // is here), without holding up anything else.
    if location.status == .undetermined {
      Task { locationStatus = await location.request() }
    }
    guard loggedIn else { return }
    await loadSpeakers()
  }

  // MARK: Running work

  /// Runs blocking work off the main thread. While it runs, `label` is shown
  /// in the status bar; errors become a red status message and nil.
  @discardableResult
  func perform<T>(_ label: String? = nil, _ work: @escaping () throws -> T) async -> T? {
    let busy = label.map { StatusMessage(kind: .busy, text: $0) }
    if let busy { status = busy }
    let result = await Task.detached { Result { try work() } }.value
    if let busy, status == busy { status = nil }
    switch result {
    case .success(let value): return value
    case .failure(let error):
      fail(error.userMessage)
      if (error as? BackendError)?.message.hasPrefix("session expired") == true { forgetAccount() }
      return nil
    }
  }

  func notify(_ text: String) {
    let message = StatusMessage(kind: .ok, text: text)
    status = message
    Task {
      try? await Task.sleep(for: .seconds(6))
      if status == message { status = nil }
    }
  }

  func fail(_ text: String) { status = StatusMessage(kind: .error, text: text) }

  // MARK: Account

  func login(email: String, password: String) async -> Bool {
    let backend = backend
    guard await perform("Logging in…", { try backend.login(username: email, password: password) }) != nil else { return false }
    loggedIn = true
    await loadSpeakers()
    if speakers.count == 1 && settingID == nil { select(speakers[0]) }
    notify("Logged in as \(email.trimmingCharacters(in: .whitespaces))")
    return true
  }

  func logout() {
    backend.logout()
    forgetAccount()
    notify("Logged out")
  }

  private func forgetAccount() {
    loggedIn = backend.isLoggedIn
    speakers = []
    catalogPath = []
    searchPath = []
  }

  func loadSpeakers() async {
    let backend = backend
    guard let list = await perform("Loading speakers…", { try backend.speakers() }) else { return }
    speakers = list.compactMap { s in
      s.id("id").map { Speaker(id: $0, name: s.text("speaker_name") ?? "(unnamed)", toSync: s.int("toSyncCount")) }
    }
    if settingID == nil, speakers.count == 1 { select(speakers[0]) }
  }

  func select(_ speaker: Speaker) {
    guard speaker.id != settingID else { return }
    config.settingID = speaker.id
    settingID = speaker.id
    backend.settingID = speaker.id
    catalogPath = []
    searchPath = []
    contentVersion += 1
  }

  // MARK: Library

  /// Opens (or creates) the library in dir.
  @discardableResult
  func openLibrary(at dir: URL, remember: Bool = true) -> Bool {
    do {
      let lib = try MediaLibrary(root: dir.standardizedFileURL)
      lib.cleanScratch()
      let adopted = lib.adoptCovers()
      library = lib
      libraryError = nil
      if remember { UserDefaults.standard.set(lib.root.path, forKey: Self.libraryPathKey) }
      libraryChanged()
      let old = lib.tracksWithoutEmbeddedArtwork()
      if !old.isEmpty { tasks.add([LibraryTasks.Job(title: "Covers", work: .artwork(old, migration: true))]) }
      refreshArtwork(adopted.filter { !old.contains($0) })
      return true
    } catch {
      libraryError = "\(dir.path): \(error.userMessage)"
      if remember { fail("Couldn't open the library: \(error.userMessage)") }
      return false
    }
  }

  func libraryChanged() {
    libraryVersion += 1
    inLibrary = library?.merlinContentIDs() ?? []
    player.libraryChanged(library)
    collectionsInLibrary = library?.merlinCollectionCounts() ?? [:]
    backup?.libraryChanged()
  }

  enum DownloadState: Equatable {
    case none, downloading, downloaded
    /// Some episodes of a collection.
    case partial(Int)
  }

  /// Whether a catalog episode or collection is in the library.
  func downloadState(_ item: CatalogItem) -> DownloadState {
    switch item.kind {
    case .content:
      if inLibrary.contains(item.itemID) { return .downloaded }
      return tasks.catalogIDs.contains(item.itemID) ? .downloading : .none
    case .collection:
      if tasks.catalogIDs.contains(item.itemID) { return .downloading }
      let n = collectionsInLibrary[item.itemID] ?? 0
      if n == 0 { return .none }
      return item.episodeCount > 0 && n >= item.episodeCount ? .downloaded : .partial(n)
    default:
      return .none
    }
  }

  /// Runs a quick library change; errors go to the status bar.
  func edit(_ what: String, _ change: (MediaLibrary) throws -> Void) {
    guard let library else { return }
    do {
      try change(library)
    } catch {
      fail("\(what): \(error.userMessage)")
    }
    libraryChanged()
  }

  /// size: the episode's audio size from the catalog (0: unknown).
  func download(contents items: [(id: String, title: String, size: Int64)], collection: String? = nil) {
    guard loggedIn else { return fail("Log in to download from the Merlin catalog") }
    let todo = items.filter { !inLibrary.contains($0.id) }
    guard !todo.isEmpty else { return notify("Already in your library") }
    tasks.add(todo.map { LibraryTasks.Job(title: $0.title, work: .content(id: $0.id, collection: collection), expected: $0.size) })
  }

  /// size: the missing episodes' total, when known (else learned when it starts).
  func download(collection id: String, title: String, size: Int64 = 0) {
    guard loggedIn else { return fail("Log in to download from the Merlin catalog") }
    tasks.add([LibraryTasks.Job(title: title, work: .collection(id: id), expected: size)])
  }

  /// Copies the episodes bought for a speaker into the library.
  func importPurchases(from speaker: Speaker) {
    guard loggedIn else { return fail("Log in to import purchases") }
    tasks.add([LibraryTasks.Job(title: "Purchases on \(speaker.name)", work: .purchases(setting: speaker.id, speaker: speaker.name))])
  }

  func importFiles(_ files: [URL], into destination: MediaLibrary.ImportDestination) {
    tasks.add(files.map { LibraryTasks.Job(title: $0.lastPathComponent, work: .file($0, destination)) })
  }

  /// A folder's cover changed or tracks moved: rewrite the covers inside the files.
  func refreshArtwork(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    tasks.add([LibraryTasks.Job(title: "Covers", work: .artwork(ids, migration: false))])
  }

  func revealLibrary() {
    guard let library else { return }
    NSWorkspace.shared.activateFileViewerSelecting([library.root.appendingPathComponent(MediaLibrary.databaseName)])
  }

  func chooseLibraryFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use This Folder"
    panel.message = "Choose a folder for your library. A folder that already holds a Merlin library is opened as is."
    panel.directoryURL = library?.root.deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard !tasks.isBusy else { return fail("Wait for the downloads and imports to finish first") }
    guard backup.running == nil else { return fail("Wait for the backup to finish first") }
    if openLibrary(at: url) { notify("Library: \(url.path)") }
  }

  // MARK: Sync

  func startSync(isolate: Bool) async {
    guard syncSession?.isRunning != true else { return }
    if isolate && !isolation.isAuthorized {
      let iso = isolation
      guard await perform("Waiting for the admin password…", { try iso.authorize() }) != nil else {
        if let s = status, s.kind == .error { fail("\(s.text) — turn the traffic filter off to sync without it") }
        return
      }
    }
    let session = SyncSession(app: self, isolation: isolate ? isolation : nil)
    syncSession = session
    session.start()
  }

  func syncEnded() {
    libraryChanged()
    Task { await loadSpeakers() }
  }

  func removeLeftoverFilter() async {
    let iso = isolation
    let done: Void? = await perform("Removing the traffic filter…") {
      try iso.authorize()
      if iso.hasLeftover { try iso.releaseLeftover() } else { try iso.disable() }
    }
    if done != nil { notify("Traffic filter removed") }
  }

  // MARK: iPod

  func refreshIPods() {
    let found = IPodDevice.connected()
    if found != ipods { ipods = found }
  }

  func startIPod(_ device: IPodDevice, job: IPodSession.Job) {
    guard ipodSession?.isRunning != true else { return }
    let session = IPodSession(device: device, job: job)
    ipodSession = session
    section = .ipod
    session.start(app: self)
  }

  func ipodsChanged() {
    ipodVersion += 1
    refreshIPods()
  }

  func eject(_ device: IPodDevice) {
    let url = device.mountPoint
    Task {
      let error: String? = await Task.detached {
        do {
          try NSWorkspace.shared.unmountAndEjectDevice(at: url)
          return nil
        } catch {
          return error.localizedDescription
        }
      }.value
      if let error { fail("Couldn't eject \(device.volumeName): \(error)") } else { notify("\(device.volumeName) ejected — you can unplug it") }
      refreshIPods()
    }
  }

  func openLogs() {
    try? FileManager.default.createDirectory(at: config.logDir, withIntermediateDirectories: true)
    NSWorkspace.shared.open(config.logDir)
  }

  /// Called when the app quits: the root helper exits with us.
  func shutdown() {
    isolation.shutdownHelper()
  }
}
