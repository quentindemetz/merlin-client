import AppKit
import MerlinCore
import SwiftUI

/// Copying to (or clearing) an iPod, in the background, with a log.
@MainActor @Observable
final class IPodSession {
  enum State: Equatable { case running, done, failed, aborted }
  enum Job { case copy, remove }

  let device: IPodDevice
  let job: Job
  private(set) var state: State = .running
  private(set) var lines: [String] = []
  private(set) var errorMessage: String?
  private(set) var outcome: String?

  @ObservationIgnored let log = SyncLog()
  @ObservationIgnored private let cancel = CancelToken()
  @ObservationIgnored private var refreshPending = false

  var isRunning: Bool { state == .running }

  init(device: IPodDevice, job: Job) {
    self.device = device
    self.job = job
    log.onChange = { [weak self] in DispatchQueue.main.async { self?.scheduleRefresh() } }
  }

  func start(app: AppModel) {
    let log = log, cancel = cancel, device = device, job = job
    let library = app.library, converted = app.config.cacheDir.appendingPathComponent("converted")
    let thread = Thread { [weak self] in
      var state: State = .done
      var message: String?
      var outcome: String?
      do {
        let transfer = IPodTransfer(device: device, out: log, cancel: cancel)
        switch job {
        case .copy:
          guard let library else { throw MerlinError("the library can't be opened") }
          let content = try IPodContent.build(library: library, target: IPodContent.target(device), converted: converted,
                                              cancel: cancel, say: { log.line($0) })
          log.line("\(content.items.count) track(s) in \(content.folders.count) folder(s) from your library")
          if !content.missing.isEmpty {
            log.line("warning: \(content.missing.count) track(s) missing from the library folder, skipped: \(content.missing.prefix(5).joined(separator: ", "))\(content.missing.count > 5 ? "…" : "")")
          }
          log.line("Copying to \(device.volumeName)…")
          let s = try transfer.run(content)
          outcome = "\(s.copied) copied, \(s.kept) already there, \(s.removed) removed · \(s.playlists) playlist(s), \(s.covers) cover(s)"
        case .remove:
          let n = try transfer.removeAll()
          outcome = "\(n) Merlin track(s) removed"
        }
        if let outcome { log.line(outcome) }
      } catch is CancellationError {
        state = .aborted
        log.line("Cancelled. The iPod was left as it was.")
      } catch {
        state = .failed
        message = error.userMessage
        log.line("Error: \(error.userMessage)")
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.state = state
        self.errorMessage = message
        self.outcome = outcome
        self.refresh()
        app.ipodsChanged()
      }
    }
    thread.name = "Merlin iPod"
    thread.start()
  }

  func abort() { cancel.cancel() }

  private func scheduleRefresh() {
    guard !refreshPending else { return }
    refreshPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.refreshPending = false
      self?.refresh()
    }
  }

  private func refresh() { lines = log.lines }
}

/// What the iPod holds now, read off the main thread.
struct IPodStatus {
  var tracks: Int?
  var merlinTracks = 0
  var problem: String?
  var readError: String?

  static func read(_ device: IPodDevice) -> IPodStatus {
    var status = IPodStatus()
    var db: ITunesDB?
    if let data = try? Data(contentsOf: device.databaseURL) {
      do {
        db = try ITunesDB(data: data)
        status.tracks = db?.trackCount
      } catch {
        status.readError = "\(error)"
      }
    }
    status.problem = device.problem(existing: db)
    status.merlinTracks = IPodTransfer(device: device, out: SyncLog()).merlinTrackCount()
    return status
  }
}

struct IPodView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Group {
      if let session = app.ipodSession {
        IPodSessionView(session: session)
      } else if app.ipods.isEmpty {
        NoIPodView()
      } else {
        IPodStartView()
      }
    }
    .navigationTitle("iPod")
  }
}

struct IPodStartView: View {
  @Environment(AppModel.self) private var app
  @ViewState private var selected: String?
  @ViewState private var status: IPodStatus?
  @ViewState private var confirmRemove = false

  private var device: IPodDevice? { app.ipods.first { $0.id == selected } ?? app.ipods.first }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let device {
          header(device)
          Text("Copies the folders checked below. Each folder becomes an album and a playlist, under the genre “Merlin”; tracks without an artist get their section as artist. Your music already on the iPod stays.")
            .fixedSize(horizontal: false, vertical: true)

          SyncSelection(target: IPodContent.target(device))

          if let problem = status?.problem ?? status?.readError {
            notice("exclamationmark.triangle.fill", .red, "Merlin can't write to this iPod", problem)
          } else {
            notice("info.circle", .secondary, "Turn off automatic syncing in Finder",
                   "If Finder syncs this iPod with the Music app, it may remove what Merlin copied. Select the iPod in Finder and choose to manage music manually.")
          }

          HStack(spacing: 12) {
            Button {
              app.startIPod(device, job: .copy)
            } label: {
              Label("Copy to iPod", systemImage: "arrow.down.to.line").frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(status == nil || status?.problem != nil || status?.readError != nil || app.library == nil)

            Button("Remove Merlin Content…") { confirmRemove = true }
              .controlSize(.large)
              .disabled((status?.merlinTracks ?? 0) == 0 || status?.problem != nil)

            Spacer()
            Button { app.eject(device) } label: { Label("Eject", systemImage: "eject") }
              .controlSize(.large)
          }
          .confirmationDialog("Remove what Merlin copied to \(device.volumeName)?", isPresented: $confirmRemove) {
            Button("Remove \(status?.merlinTracks ?? 0) Track(s)", role: .destructive) { app.startIPod(device, job: .remove) }
          } message: {
            Text("Your own music and playlists stay on the iPod.")
          }
        }
      }
      .padding(28)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .task(id: [device?.id ?? "", String(app.ipodVersion)]) {
      status = nil
      guard let device else { return }
      status = await Task.detached { IPodStatus.read(device) }.value
    }
  }

  private func header(_ device: IPodDevice) -> some View {
    HStack(spacing: 14) {
      Image(systemName: "ipod").font(.system(size: 44)).foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        if app.ipods.count > 1 {
          Picker("iPod", selection: Binding(get: { device.id }, set: { selected = $0 })) {
            ForEach(app.ipods) { Text($0.volumeName).tag($0.id) }
          }
          .labelsHidden()
          .fixedSize()
        } else {
          Text(device.volumeName).font(.title2.bold())
        }
        Text(device.modelName).foregroundStyle(.secondary)
        Text(details(device)).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func details(_ device: IPodDevice) -> String {
    let free = ByteCountFormatter.string(fromByteCount: device.freeSpace, countStyle: .file)
    guard let status else { return "\(free) free" }
    var parts = ["\(free) free"]
    if let n = status.tracks { parts.append("\(n) track(s)") }
    if status.merlinTracks > 0 { parts.append("\(status.merlinTracks) from Merlin") }
    return parts.joined(separator: " · ")
  }

  private func notice(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
    GroupBox {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: symbol).foregroundStyle(color)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).bold()
          Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(4)
    }
  }
}

struct IPodSessionView: View {
  let session: IPodSession
  @Environment(AppModel.self) private var app

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Group {
          switch session.state {
          case .running: ProgressView().controlSize(.small)
          case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
          case .aborted: Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
          }
        }
        .font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          if let detail = session.state == .failed ? session.errorMessage : session.outcome {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Spacer()
        if session.isRunning {
          Button("Cancel", role: .cancel) { session.abort() }
        } else {
          if session.state == .done, app.ipods.contains(session.device) {
            Button { app.eject(session.device) } label: { Label("Eject", systemImage: "eject") }
          }
          Button("Done") { app.ipodSession = nil }.keyboardShortcut(.defaultAction)
        }
      }
      .padding()
      Divider()
      LogView(lines: session.lines)
    }
  }

  private var title: String {
    let name = session.device.volumeName
    switch (session.state, session.job) {
    case (.running, .copy): return "Copying to \(name)…"
    case (.running, .remove): return "Removing Merlin content from \(name)…"
    case (.done, .copy): return "\(name) is up to date"
    case (.done, .remove): return "Merlin content removed"
    case (.failed, _): return "Couldn't update \(name)"
    case (.aborted, _): return "Cancelled"
    }
  }
}

/// No iPod mounted: says whether one is plugged in anyway (on USB, without
/// a disk, or with a disk macOS didn't mount), checking every 2 seconds.
struct NoIPodView: View {
  @Environment(AppModel.self) private var app
  @ViewState private var usb: [IPodUSB] = []
  @ViewState private var mounting = false

  var body: some View {
    Group {
      if let ipod = usb.first(where: \.hasDisk) {
        ContentUnavailableView {
          Label("\(ipod.name) isn't mounted", systemImage: "ipod")
        } description: {
          VStack(alignment: .leading, spacing: 8) {
            Text("Your iPod is plugged in and has a disk, but it isn't mounted. Usually Finder took it: its device service unmounts an iPod a few seconds after it mounts, unless disk use is on.")
            Text("In Finder, select the iPod in the sidebar and, under Options, turn on “Enable disk use” and “Manually manage music”, then click Apply.")
          }
          .multilineTextAlignment(.leading)
          .frame(maxWidth: 520)
        } actions: {
          Button(mounting ? "Mounting…" : "Mount iPod") { mount(ipod) }
            .buttonStyle(.borderedProminent)
            .disabled(mounting)
        }
      } else if let ipod = usb.first {
        ContentUnavailableView {
          Label("\(ipod.name) is plugged in, but has no disk", systemImage: "exclamationmark.triangle")
        } description: {
          VStack(alignment: .leading, spacing: 8) {
            Text("macOS sees the iPod on USB, but its disk isn't available. Try, in order:")
            Text("1. In Finder, select the iPod in the sidebar and, under Options, turn on “Enable disk use” and “Manually manage music”, then click Apply. Without it, Finder's device service unmounts and releases the iPod a few seconds after it mounts.")
            Text("2. Unplug the iPod and plug it back in, directly into this Mac rather than through a hub.")
            Text("3. Put it in disk mode: hold Menu and Select until the Apple logo appears, then at once hold Select and Play/Pause until “Disk Mode” shows.")
            Text("4. If it still doesn't appear (or the iPod clicks or shows a sad face), its hard drive may be failing.")
          }
          .multilineTextAlignment(.leading)
          .frame(maxWidth: 520)
        }
      } else {
        ContentUnavailableView {
          Label("Connect an iPod", systemImage: "ipod")
        } description: {
          Text("Plug in an iPod with a click wheel (classic, video, nano up to the 4th generation, mini…). It shows up here as soon as it appears in Finder.")
        }
      }
    }
    .task {
      while !Task.isCancelled {
        let found = await Task.detached { IPodUSB.connected() }.value
        if found != usb { usb = found }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func mount(_ ipod: IPodUSB) {
    mounting = true
    Task {
      let error: String? = await Task.detached {
        do { try ipod.mount(); return nil } catch { return error.userMessage }
      }.value
      mounting = false
      if let error { app.fail(error) }
      app.refreshIPods()
    }
  }
}
