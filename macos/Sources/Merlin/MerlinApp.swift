import AppKit
import MerlinCore
import SwiftUI

@main
struct MerlinApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Window("Merlin", id: "main") {
      RootView()
        .environment(delegate.model)
        .frame(minWidth: 820, minHeight: 520)
        .task { await delegate.model.start() }
    }
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Library") {
        Button("Show Library") { delegate.model.section = .library }
          .keyboardShortcut("1", modifiers: .command)
        Button("Show Library in Finder") { delegate.model.revealLibrary() }
          .disabled(delegate.model.library == nil)
        Button("Choose Library Folder…") { delegate.model.chooseLibraryFolder() }
        Divider()
        Menu("Import Purchases from Speaker") {
          ForEach(delegate.model.speakers) { s in
            Button(s.name) { delegate.model.importPurchases(from: s) }
          }
        }
        .disabled(delegate.model.library == nil || delegate.model.speakers.isEmpty)
        Divider()
        Button("Cancel Downloads and Imports") { delegate.model.tasks.cancelAll() }
          .disabled(!delegate.model.tasks.isBusy)
      }
      CommandMenu("Controls") {
        let player = delegate.model.player
        Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
          .keyboardShortcut("p", modifiers: [.command, .option])
          .disabled(player.current == nil)
        Button("Next Track") { player.next() }
          .keyboardShortcut(.rightArrow, modifiers: .command)
          .disabled(!player.hasNext)
        Button("Previous Track") { player.previous() }
          .keyboardShortcut(.leftArrow, modifiers: .command)
          .disabled(player.current == nil)
        Divider()
        Button("Stop") { player.stop() }
          .disabled(player.current == nil)
      }
      CommandMenu("Speaker") {
        Button("Sync Speaker") { delegate.model.section = .sync }
          .keyboardShortcut("s", modifiers: [.command, .shift])
        Divider()
        Button("Copy to iPod") {
          if let ipod = delegate.model.ipods.first { delegate.model.startIPod(ipod, job: .copy) }
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(delegate.model.library == nil || delegate.model.ipods.isEmpty || delegate.model.ipodSession?.isRunning == true)
        Divider()
        Button("Show Logs Folder") { delegate.model.openLogs() }
        Button("Remove Traffic Filter…") { Task { await delegate.model.removeLeftoverFilter() } }
          .help("If a transfer died, remove the network filter it left behind")
        Divider()
        Button("Log Out") { delegate.model.logout() }
          .disabled(!delegate.model.loggedIn || delegate.model.syncSession?.isActive == true)
      }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  /// A transfer in progress is aborted (and reported); one that is
  /// reconnecting / reporting gets a bounded time to finish.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if let copy = model.ipodSession, copy.isRunning {
      // Cancelling removes the files copied so far and leaves the iPod as it was.
      copy.abort()
      Task { @MainActor in
        for _ in 0..<100 where copy.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
    guard let session = model.syncSession, session.isActive else { return .terminateNow }
    if session.isRunning {
      let alert = NSAlert()
      alert.messageText = "A transfer is in progress"
      alert.informativeText = "Quitting aborts it. This Mac then reconnects to your usual network and reports the abort to Merlin."
      alert.addButton(withTitle: "Abort and Quit")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
      session.abort()
    }
    model.status = StatusMessage(kind: .busy, text: "Reconnecting and reporting before quitting…")
    DispatchQueue.global().async {
      session.waitUntilFinished(timeout: 90)
      DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.shutdown()
  }
}

struct RootView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    MainView()
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          PlayerBar()
          TasksBar()
          StatusBar()
        }
      }
  }
}

struct MainView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    NavigationSplitView {
      List(selection: $app.section) {
        Section {
          Label("Library", systemImage: "music.note.house")
            .badge(app.library?.trackCount ?? 0)
            .tag(SidebarItem.library)
        }
        Section("Merlin Catalog") {
          Label("Browse", systemImage: "books.vertical").tag(SidebarItem.catalog)
          Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
        }
        Section("Send To") {
          Label {
            Text(app.currentSpeaker?.name ?? "Speaker").lineLimit(1)
          } icon: {
            Image(systemName: "hifispeaker")
              .symbolEffect(.pulse, isActive: app.syncSession?.isRunning == true)
          }
          .tag(SidebarItem.sync)
          Label {
            Text(app.ipods.first?.volumeName ?? "iPod").lineLimit(1)
          } icon: {
            Image(systemName: "ipod")
              .symbolEffect(.pulse, isActive: app.ipodSession?.isRunning == true)
          }
          .badge(app.ipods.count)
          .tag(SidebarItem.ipod)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    } detail: {
      let section = app.section ?? .library
      let _ = app.libraryVersion
      if (section == .catalog || section == .search) && !app.loggedIn {
        LoginView(reason: "Log in with your Hello Merlin account to browse the catalog and download episodes to your library.")
      } else if (section == .catalog || section == .search) && app.settingID == nil {
        ContentUnavailableView("Choose your speaker", systemImage: "hifispeaker",
                               description: Text(app.speakers.isEmpty
                                 ? "No speaker on this account — pair one with the mobile app first."
                                 : "The catalog depends on the speaker: pick one in Send To › Speaker."))
      } else {
        switch section {
        case .library: LibraryView()
        case .catalog: CatalogBrowser()
        case .search: SearchView()
        case .sync: SyncView()
        case .ipod: IPodView()
        }
      }
    }
  }
}

struct SpeakerPicker: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Menu {
      ForEach(app.speakers) { s in
        Button {
          app.select(s)
        } label: {
          if s.id == app.settingID { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
        }
      }
      if !app.speakers.isEmpty { Divider() }
      Button("Refresh Speakers") { Task { await app.loadSpeakers() } }
    } label: {
      Text(app.currentSpeaker.map { "Speaker: \($0.name)" } ?? "Choose a speaker").lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(app.syncSession?.isActive == true)
    .help("The speaker to send your library to")
  }
}

struct StatusBar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    if let status = app.status {
      HStack(spacing: 8) {
        switch status.kind {
        case .busy: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        Text(status.text).lineLimit(2).textSelection(.enabled)
        Spacer()
        if status.kind != .busy {
          Button { app.status = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}

/// Downloads and imports in progress.
struct TasksBar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let tasks: LibraryTasks = app.tasks
    if tasks.isBusy {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(tasks.total > 1 ? "\(tasks.finished + 1) of \(tasks.total): \(tasks.current?.title ?? "…")" : tasks.current?.title ?? "…")
            .lineLimit(1)
          Spacer()
          Button("Cancel") { tasks.cancelAll() }.buttonStyle(.borderless)
        }
        if tasks.isImporting {
          ProgressView(value: Double(tasks.finished), total: Double(max(tasks.total, 1)))
          Text("Importing file \(tasks.finished + 1) of \(tasks.total)")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if let fraction = tasks.fraction {
          ProgressView(value: fraction)
          TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(Self.figures(tasks, fraction)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
        } else {
          ProgressView().progressViewStyle(.linear)
          if let detail = tasks.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
  }

  /// "120 MB of 456 MB · 26 % · 3.2 MB/s · about 2 min left"
  static func figures(_ tasks: LibraryTasks, _ fraction: Double) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    var parts = ["\(f.string(fromByteCount: tasks.bytesReceived)) of \(f.string(fromByteCount: tasks.bytesTotal))",
                 "\(Int(fraction * 100)) %"]
    let speed = tasks.speed
    if speed > 0 {
      parts.append("\(f.string(fromByteCount: Int64(speed)))/s")
      let left = Double(tasks.bytesTotal - tasks.bytesReceived) / speed
      if left >= 1 {
        let d = DateComponentsFormatter()
        d.unitsStyle = .abbreviated
        d.allowedUnits = left >= 3600 ? [.hour, .minute] : left >= 60 ? [.minute] : [.second]
        parts.append("about \(d.string(from: left) ?? "") left")
      }
    }
    return parts.joined(separator: " · ")
  }
}
