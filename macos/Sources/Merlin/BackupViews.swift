import MerlinCore
import SwiftUI

/// Merlin › Settings… : where the library is backed up.
struct BackupSettingsView: View {
  @Environment(AppModel.self) private var app
  @ViewState private var draft = BackupSettings()
  @ViewState private var secret = ""
  @ViewState private var testResult: (ok: Bool, text: String)?
  @ViewState private var testing = false
  @ViewState private var loaded = false

  var body: some View {
    let backup: BackupModel = app.backup
    Form {
      Section {
        TextField("Bucket", text: $draft.bucket, prompt: Text("merlin-library-backup-…"))
        TextField("Region", text: $draft.region, prompt: Text("eu-west-1"))
        TextField("Folder in bucket", text: $draft.prefix, prompt: Text("optional"))
      } header: {
        Text("Amazon S3")
      } footer: {
        Text("The bucket and the access key are made by infra/backup in the repository (see the README).")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Access key") {
        TextField("Access key ID", text: $draft.accessKeyID, prompt: Text("AKIA…"))
        SecureField("Secret access key", text: $secret,
                    prompt: Text(backup.hasSecret && draft.accessKeyID == backup.settings.accessKeyID ? "saved in the Keychain" : "required"))
      }
      Section {
        Toggle("Back up automatically after changes", isOn: $draft.automatic)
        if let last = backup.lastResult {
          LabeledContent("Last backup") { Text(last).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        if let r = testResult {
          Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(r.ok ? .green : .red)
        }
      }
      HStack {
        Button("Test Connection") { Task { await test() } }
          .disabled(testing || !draftComplete)
        if testing { ProgressView().controlSize(.small) }
        Spacer()
        Button("Back Up Now") {
          save()
          Task { await backup.backUp() }
        }
        .disabled(!draftComplete || backup.running != nil || app.library == nil)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(draft == backup.settings && secret.isEmpty)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      draft = backup.settings
    }
  }

  private var draftComplete: Bool {
    draft.isConfigured && (!secret.isEmpty || (app.backup.hasSecret && draft.accessKeyID == app.backup.settings.accessKeyID))
  }

  private func save() {
    do {
      try app.backup.save(draft, secret: secret)
      secret = ""
      draft = app.backup.settings
    } catch {
      testResult = (false, error.userMessage)
    }
  }

  private func test() async {
    testing = true
    defer { testing = false }
    do {
      testResult = (true, try await app.backup.test(draft, secret: secret))
    } catch {
      testResult = (false, error.userMessage)
    }
  }
}

/// Library › Backup Settings…: opens the Settings window. (Since macOS 14 the
/// Settings scene only opens through `openSettings`; the old
/// `showSettingsWindow:` action does nothing.)
struct BackupSettingsButton: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Backup Settings…") {
      NSApp.activate()
      openSettings()
    }
  }
}

/// A backup or restore in progress.
struct BackupBar: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let backup: BackupModel = app.backup
    if let kind = backup.running {
      let p = backup.progress
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Image(systemName: kind == .backup ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
          Text(Self.title(kind, p, bucket: backup.settings.bucket)).lineLimit(1)
          Spacer()
          Button("Cancel") { backup.cancelRunning() }.buttonStyle(.borderless)
        }
        if let p, p.phase == .transferring, p.bytesTotal > 0 {
          ProgressView(value: Double(p.bytesDone), total: Double(p.bytesTotal))
          Text("\(p.filesDone) of \(p.filesTotal) file(s) · \(BackupModel.bytes(p.bytesDone)) of \(BackupModel.bytes(p.bytesTotal))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else {
          ProgressView().progressViewStyle(.linear)
        }
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
  }

  static func title(_ kind: BackupModel.Kind, _ p: LibraryBackup.Progress?, bucket: String) -> String {
    let verb = kind == .backup ? "Backing up to \(bucket)" : "Restoring from \(bucket)"
    switch p?.phase {
    case .checking where kind == .backup && (p?.filesTotal ?? 0) > 0: return "\(verb): checking \(p!.filesDone) of \(p!.filesTotal) file(s)…"
    case .finishing: return "\(verb): finishing…"
    default: return "\(verb)…"
    }
  }
}
