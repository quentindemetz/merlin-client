import MerlinCore
import SwiftUI

// MARK: - Login

struct LoginView: View {
  /// Why an account is needed here.
  var reason = "Log in with your Hello Merlin account"
  @Environment(AppModel.self) private var app
  @ViewState private var email = ""
  @ViewState private var password = ""
  @ViewState private var busy = false

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "hifispeaker.fill")
        .font(.system(size: 56))
        .foregroundStyle(.tint)
      VStack(spacing: 4) {
        Text("Merlin").font(.largeTitle.bold())
        Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
      }
      Form {
        TextField("Email", text: $email, prompt: Text("you@example.com")).textContentType(.username)
        SecureField("Password", text: $password, prompt: Text("Required")).textContentType(.password)
      }
      .formStyle(.grouped)
      .frame(width: 360)
      .fixedSize(horizontal: false, vertical: true)
      Button {
        busy = true
        Task {
          _ = await app.login(email: email, password: password)
          busy = false
        }
      } label: {
        Text("Log In").frame(width: 120)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)
      .disabled(busy || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
      Text("Your password is sent to Hello Merlin only; it is never stored.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
