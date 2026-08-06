import SwiftUI
import JarvisCore

/// First-run pane that writes API keys straight to the Keychain — keys never
/// live in UserDefaults, plists, or source.
@MainActor
struct APIKeysView: View {
    @State private var anthropicKey = ""
    @State private var elevenLabsKey = ""
    @State private var statusMessage: String?

    private let keychain = KeychainStore()

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("sk-ant-…", text: $anthropicKey)
                    .textContentType(.password)
            }
            Section("ElevenLabs") {
                SecureField("API key", text: $elevenLabsKey)
                    .textContentType(.password)
            }
            Section {
                HStack {
                    Button("Save to Keychain") { save() }
                        .keyboardShortcut(.defaultAction)
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .onAppear(perform: load)
    }

    private func load() {
        anthropicKey = (try? keychain.get(.anthropicAPIKey)) ?? ""
        elevenLabsKey = (try? keychain.get(.elevenLabsAPIKey)) ?? ""
    }

    private func save() {
        do {
            try store(anthropicKey, as: .anthropicAPIKey)
            try store(elevenLabsKey, as: .elevenLabsAPIKey)
            AppState.shared.invalidateKeyCache()
            statusMessage = "Saved."
        } catch {
            statusMessage = "Keychain error: \(error)"
        }
    }

    private func store(_ value: String, as key: KeychainStore.Key) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(key)
        } else {
            try keychain.set(trimmed, for: key)
        }
    }
}
