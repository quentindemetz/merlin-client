import AppKit
import MerlinCore
import Observation

/// Backups of the library to S3 (Library › Back Up Now, and automatically a
/// little after changes) and restores from it.
@MainActor @Observable
final class BackupModel {
  enum Kind { case backup, restore }

  private(set) var settings: BackupSettings
  private(set) var running: Kind?
  private(set) var progress: LibraryBackup.Progress?
  /// "Backed up 12 Nov at 10:42" / the last error, for the settings pane.
  private(set) var lastResult: String?

  @ObservationIgnored private weak var app: AppModel?
  @ObservationIgnored private var cancel = CancelToken()
  @ObservationIgnored private var autoTask: Task<Void, Never>?
  /// A change came in while a backup ran: back up again after it.
  @ObservationIgnored private var changedDuringRun = false

  /// Quiet time after the last change before an automatic backup.
  static let autoDelay: Duration = .seconds(90)

  init(app: AppModel) {
    self.app = app
    settings = BackupSettings.load(app.config)
    lastResult = app.config.settings["backup_last"] as? String
  }

  var isConfigured: Bool { settings.isConfigured && hasSecret }
  var hasSecret: Bool { secret != nil }

  /// Read from the Keychain once (each read of an ad-hoc signed app's item
  /// can ask for the login password).
  @ObservationIgnored private var cachedSecret: (key: String, value: String?)?
  private var secret: String? {
    if let c = cachedSecret, c.key == settings.accessKeyID { return c.value }
    let value = settings.accessKeyID.isEmpty ? nil : BackupKeychain.secret(for: settings.accessKeyID)
    cachedSecret = (settings.accessKeyID, value)
    return value
  }

  func save(_ new: BackupSettings, secret: String?) throws {
    let id = new.accessKeyID.trimmingCharacters(in: .whitespaces)
    if let secret, !secret.isEmpty {
      let value = secret.trimmingCharacters(in: .whitespaces)
      try BackupKeychain.setSecret(value, for: id)
      cachedSecret = (id, value)
    }
    guard let app else { return }
    new.save(app.config)
    settings = BackupSettings.load(app.config)
  }

  private func engine(_ settings: BackupSettings, secret: String? = nil) throws -> LibraryBackup {
    guard settings.isConfigured else { throw MerlinError("set up the backup first (Merlin › Settings…)") }
    guard let secret = secret ?? (settings.accessKeyID == self.settings.accessKeyID ? self.secret : BackupKeychain.secret(for: settings.accessKeyID)) else {
      throw MerlinError("the backup's secret access key isn't in the Keychain: enter it in Merlin › Settings…")
    }
    let store = S3Client(bucket: settings.bucket, region: settings.region,
                         credentials: AWSCredentials(accessKeyID: settings.accessKeyID, secretAccessKey: secret))
    let config = app?.config ?? Config()
    return LibraryBackup(store: store, prefix: settings.normalizedPrefix, indexDir: config.cacheDir.appendingPathComponent("backup"),
                         cancel: cancel)
  }

  /// Checks the settings against the bucket; returns what it holds.
  func test(_ settings: BackupSettings, secret: String?) async throws -> String {
    let backup = try engine(settings, secret: secret?.isEmpty == false ? secret : nil)
    let manifest = try await Task.detached { try backup.manifest() }.value
    guard let m = manifest else { return "Connected — the bucket holds no backup yet" }
    return "Connected — backup of \(m.tracks) track(s), \(Self.bytes(m.bytes)), \(m.date.formatted(date: .abbreviated, time: .shortened))"
  }

  // MARK: Backup

  /// The library changed: back up once things settle.
  func libraryChanged() {
    guard settings.automatic, isConfigured else { return }
    if running != nil { changedDuringRun = true; return }
    autoTask?.cancel()
    autoTask = Task { [weak self] in
      try? await Task.sleep(for: Self.autoDelay)
      guard !Task.isCancelled else { return }
      self?.autoBackUp()
    }
  }

  private func autoBackUp() {
    guard let app else { return }
    // Not while downloads run (more changes coming) or while the Mac is on
    // the speaker's Wi-Fi (no internet): try again later.
    if app.tasks.isBusy || app.syncSession?.isActive == true { return libraryChanged() }
    Task { await backUp(manual: false) }
  }

  func backUp(manual: Bool = true, replacing: Bool = false) async {
    guard let app, let library = app.library, running == nil else { return }
    autoTask?.cancel()
    cancel = CancelToken()
    changedDuringRun = false
    let backup: LibraryBackup
    do { backup = try engine(settings) } catch { return finish("Backup failed: \(error.userMessage)", error: true) }
    running = .backup
    progress = LibraryBackup.Progress(phase: .checking)
    backup.onProgress = { p in Task { @MainActor in self.progress = p } }
    let result = await Task.detached { Result { try backup.backUp(library, replacingOtherLibrary: replacing) } }.value
    running = nil
    progress = nil
    switch result {
    case .success(let s):
      var msg = "Library backed up to \(settings.bucket)"
      msg += s.transferred > 0 ? " (\(s.transferred) file(s), \(Self.bytes(s.transferredBytes)) sent)" : " (nothing new to send)"
      if !s.missing.isEmpty { msg += "; \(s.missing.count) file(s) missing from the library folder weren't backed up" }
      remember("Backed up \(Date().formatted(date: .abbreviated, time: .shortened)): \(s.files) file(s), \(Self.bytes(s.bytes))")
      if manual || !s.missing.isEmpty { s.missing.isEmpty ? app.notify(msg) : app.fail(msg) }
    case .failure(let error as LibraryBackup.OtherLibrary):
      if manual, confirmReplace(error.manifest) { return await backUp(manual: true, replacing: true) }
      finish("Backup not made: \(error.userMessage)", error: true)
    case .failure(let error) where error is CancellationError:
      app.notify("Backup cancelled")
    case .failure(let error):
      finish("Backup failed: \(error.userMessage)", error: true)
    }
    if changedDuringRun { libraryChanged() }
  }

  private func confirmReplace(_ m: LibraryBackup.Manifest) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Replace the backup of another library?"
    alert.informativeText = """
      \(settings.bucket) holds the backup of a different library (\(m.tracks) track(s), \(Self.bytes(m.bytes)), \
      made \(m.date.formatted(date: .abbreviated, time: .shortened))). Backing up this library replaces it; the bucket \
      keeps the replaced files for a while (versioning).
      """
    alert.addButton(withTitle: "Replace Backup")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: Restore

  func restore() async {
    guard let app, running == nil else { return }
    guard !app.tasks.isBusy else { return app.fail("Wait for the downloads and imports to finish first") }
    let backup: LibraryBackup
    do { backup = try engine(settings) } catch { return finish("Restore failed: \(error.userMessage)", error: true) }
    cancel = CancelToken()
    running = .restore
    progress = LibraryBackup.Progress(phase: .checking)
    let manifest = await Task.detached { Result { try backup.manifest() } }.value
    running = nil
    progress = nil
    let m: LibraryBackup.Manifest
    switch manifest {
    case .success(let found?): m = found
    case .success(nil): return app.fail("There's no backup in \(settings.bucket)")
    case .failure(let error): return finish("Restore failed: \(error.userMessage)", error: true)
    }

    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Restore Here"
    panel.message = """
      Restore the backup of \(m.tracks) track(s) (\(Self.bytes(m.bytes)), \(m.date.formatted(date: .abbreviated, time: .shortened))) \
      into a new or empty folder. It then becomes your library.
      """
    panel.directoryURL = app.library?.root.deletingLastPathComponent()
    guard panel.runModal() == .OK, let dir = panel.url else { return }
    guard !MediaLibrary.exists(at: dir) else { return app.fail("\(dir.lastPathComponent) already holds a library: choose a new or empty folder") }

    running = .restore
    backup.onProgress = { p in Task { @MainActor in self.progress = p } }
    let result = await Task.detached { Result { try backup.restore(into: dir) } }.value
    running = nil
    progress = nil
    switch result {
    case .success(let s):
      guard app.openLibrary(at: dir) else { return }
      var msg = "Library restored in \(dir.path) (\(s.files) file(s), \(Self.bytes(s.bytes)))"
      if !s.missing.isEmpty { msg += "; \(s.missing.count) file(s) weren't in the backup" }
      s.missing.isEmpty ? app.notify(msg) : app.fail(msg)
      app.section = .library
    case .failure(let error) where error is CancellationError:
      app.notify("Restore cancelled — restoring into the same folder again picks up where it stopped")
    case .failure(let error):
      finish("Restore failed: \(error.userMessage) — restoring into the same folder again picks up where it stopped", error: true)
    }
  }

  func cancelRunning() { cancel.cancel() }

  // MARK: Helpers

  private func finish(_ message: String, error: Bool) {
    if error { remember(message) }
    error ? app?.fail(message) : app?.notify(message)
  }

  private func remember(_ text: String) {
    lastResult = text
    app?.config.saveSettings(["backup_last": text])
  }

  static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
