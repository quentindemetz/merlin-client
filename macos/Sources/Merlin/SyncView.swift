import MerlinCore
import SwiftUI

struct SyncView: View {
  @Environment(AppModel.self) private var app
  @AppStorage("isolateDuringSync") private var isolate = true

  var body: some View {
    Group {
      if let session = app.syncSession {
        SessionView(session: session)
      } else if !app.loggedIn {
        LoginView(reason: "Log in with your Hello Merlin account to send your library to your speaker.")
      } else {
        start
      }
    }
    .navigationTitle("Speaker")
  }

  private var start: some View {
    let speaker = app.currentSpeaker?.name ?? "your speaker"
    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 14) {
          Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: 44)).foregroundStyle(.tint)
          VStack(alignment: .leading) {
            Text("Send your library to \(speaker)").font(.title2.bold())
            SpeakerPicker()
          }
        }
        Text("The speaker gets the folders checked below, each in its section, in place of what Merlin's servers would put on it. You'll be asked to switch the speaker's Wi-Fi on: this Mac joins it by itself, and reconnects to your usual network at the end.")
          .fixedSize(horizontal: false, vertical: true)

        if let id = app.settingID {
          SyncSelection(target: SpeakerPlaylist.target(id))
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isolate) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Keep this Mac's other traffic away from the speaker")
                Text(isolate
                  ? "Recommended. macOS asks for an administrator password once per session."
                  : "The speaker will likely crash and reboot during the transfer.")
                  .font(.caption).foregroundStyle(isolate ? Color.secondary : Color.red)
              }
            }
            .toggleStyle(.switch)
          }
          .padding(4)
        }

        if app.locationStatus == .denied {
          GroupBox {
            HStack(alignment: .top) {
              Image(systemName: "location.slash").foregroundStyle(.orange)
              VStack(alignment: .leading, spacing: 6) {
                Text("Location Services are off for Merlin").bold()
                Text("macOS only lets apps with Location access read Wi-Fi names. Without it, this Mac keeps trying to join the speaker and lets macOS pick your network back afterwards.")
                  .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Open Location Settings…") {
                  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
              }
            }
            .padding(4)
          }
        }

        Button {
          Task { await app.startSync(isolate: isolate) }
        } label: {
          Label("Start Transfer", systemImage: "play.fill").frame(minWidth: 160)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(app.settingID == nil || app.library == nil || app.syncSession?.isActive == true)
      }
      .padding(28)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

struct SessionView: View {
  let session: SyncSession
  @Environment(AppModel.self) private var app

  var body: some View {
    VStack(spacing: 0) {
      if let waiting = session.waiting, session.isRunning {
        SpeakerPrompt(waiting: waiting, home: session.homeSSID)
      } else {
        header
        Divider()
        LogView(lines: session.lines)
      }
    }
    .toolbar {
      ToolbarItem {
        if session.isRunning {
          Button(role: .destructive) { session.abort() } label: { Label("Abort", systemImage: "stop.fill") }
            .disabled(session.aborting)
            .help("Stop the transfer; the abort is reported to Merlin")
        }
      }
    }
  }

  private var header: some View {
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
        if session.reporting {
          Text("Reconnecting and reporting to Merlin…").font(.caption).foregroundStyle(.secondary)
        } else if session.state == .failed {
          Text(session.errorMessage ?? "See the log below.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer()
      if session.state == .failed {
        Button("Show Logs") { app.openLogs() }
      }
      if session.isFinished {
        Button("Done") { app.syncSession = nil }
          .keyboardShortcut(.defaultAction)
          .disabled(session.reporting)
      }
    }
    .padding()
  }

  private var title: String {
    switch session.state {
    case .running: return session.aborting ? "Aborting…" : "Transferring…"
    case .done: return "Transfer complete"
    case .failed: return "Transfer failed"
    case .aborted: return "Transfer aborted"
    }
  }
}

/// The one thing the user has to do. The Mac joins by itself as soon as the
/// speaker's network appears.
struct SpeakerPrompt: View {
  let waiting: SyncSession.Waiting
  let home: String?

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "wifi")
        .font(.system(size: 64))
        .foregroundStyle(.tint)
        .symbolEffect(.variableColor.iterative, options: .repeating)
      Text("Switch on the speaker's Wi-Fi").font(.largeTitle.bold())
      VStack(alignment: .leading, spacing: 10) {
        step(1, "Switch the speaker on")
        step(2, "Press its Wifi / Transfert button")
      }
      Text("This Mac joins \(waiting.ssid) by itself as soon as it appears, and reconnects to \(home ?? "your usual network") when the transfer is over.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 440)
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(waiting.status).foregroundStyle(.secondary)
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func step(_ n: Int, _ text: String) -> some View {
    HStack(spacing: 12) {
      Text("\(n)").font(.headline).frame(width: 28, height: 28).background(.tint.opacity(0.2), in: Circle())
      Text(text).font(.title3)
    }
  }
}

struct LogView: View {
  let lines: [String]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
            Text(line.isEmpty ? " " : line)
              .font(.system(.callout, design: .monospaced))
              .foregroundStyle(line.contains("warning") || line.hasPrefix("Error") ? Color.orange : Color.primary)
              .textSelection(.enabled)
              .id(i)
          }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .onChange(of: lines.count) { _, count in
        proxy.scrollTo(count - 1, anchor: .bottom)
      }
    }
  }
}
