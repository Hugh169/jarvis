import SwiftUI
import AppKit
import JarvisCore
import JarvisConnectors

/// Connecting a Google account to JARVIS itself, rather than to macOS.
///
/// The grant lives in this app's Keychain items and nowhere else: nothing is
/// added to Internet Accounts, and no other app on the Mac can use it.
@MainActor
struct ConnectorsView: View {
    @ObservedObject private var appState = AppState.shared

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var connected = false
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Form {
            Section("Google") {
                HStack {
                    Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(connected ? .green : .secondary)
                    Text(connected ? "Connected" : "Not connected")
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if connected {
                        Button("Disconnect", role: .destructive) { disconnect() }
                    } else {
                        Button("Connect…") { connect() }
                            .disabled(clientID.isEmpty || clientSecret.isEmpty)
                    }
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Calendar events, mail search and drafts. Sending mail always asks first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OAuth client") {
                TextField("Client ID", text: $clientID)
                SecureField("Client secret", text: $clientSecret)
                Button("Save") { saveCredentials() }
                    .disabled(clientID.isEmpty || clientSecret.isEmpty)

                Text("""
                    From a Google Cloud project of your own — console.cloud.google.com, \
                    Credentials, Create OAuth client ID, type Desktop app. Enable the \
                    Google Calendar API and the Gmail API on the same project, and add \
                    yourself as a test user on the consent screen. Both values are stored \
                    in the Keychain, never in the app's files.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link("Open Google Cloud console",
                     destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(.caption)
            }

            Section {
                Link("Review or revoke JARVIS's access at Google",
                     destination: URL(string: "https://myaccount.google.com/permissions")!)
                    .font(.caption)
                Text("Disconnecting here forgets the grant locally. Revoking it at Google "
                     + "ends it everywhere, which is the one that matters if you lose this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    /// Reads go through the async accessor: `SecItemCopyMatching` can block for
    /// as long as the approval dialog is up, and doing that on the main actor
    /// freezes the window it is supposed to be filling in.
    private func load() async {
        let store = KeychainStore()
        clientID = (try? await store.value(for: .googleClientID)).flatMap { $0 } ?? ""
        clientSecret = (try? await store.value(for: .googleClientSecret)).flatMap { $0 } ?? ""
        connected = await GoogleAccount.shared.isConnected
    }

    private func saveCredentials() {
        let store = KeychainStore()
        do {
            try store.set(clientID, for: .googleClientID)
            try store.set(clientSecret, for: .googleClientSecret)
            show("Saved.", failed: false)
        } catch {
            show(error.localizedDescription, failed: true)
        }
    }

    private func connect() {
        saveCredentials()
        busy = true
        message = nil
        Task {
            do {
                try await GoogleAccount.shared.connect { url in
                    // The consent screen has to open in the user's own browser;
                    // an embedded web view is rejected by Google outright.
                    NSWorkspace.shared.open(url)
                }
                connected = await GoogleAccount.shared.isConnected
                show("Connected.", failed: false)
            } catch {
                show(error.localizedDescription, failed: true)
            }
            busy = false
        }
    }

    private func disconnect() {
        Task {
            do {
                try await GoogleAccount.shared.disconnect()
                connected = false
                show("Disconnected.", failed: false)
            } catch {
                show(error.localizedDescription, failed: true)
            }
        }
    }

    private func show(_ text: String, failed: Bool) {
        message = text
        self.failed = failed
    }
}
