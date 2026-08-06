import SwiftUI
import JarvisCore
import JarvisVoice

/// Picks the ElevenLabs voice. Voices are fetched from the account rather than
/// hardcoded, and British ones are offered first.
@MainActor
struct VoiceSettingsView: View {
    @ObservedObject private var appState = AppState.shared

    @State private var voices: [ElevenLabsClient.Voice] = []
    @State private var isLoading = false
    @State private var status: String?
    @State private var britishOnly = true

    private var shown: [ElevenLabsClient.Voice] {
        guard britishOnly else { return voices }
        let british = voices.filter { voice in
            guard let accent = voice.accent?.lowercased() else { return false }
            return accent.contains("british") || accent.contains("english")
        }
        return british.isEmpty ? voices : british
    }

    var body: some View {
        Form {
            Section("Voice") {
                if voices.isEmpty {
                    Text(isLoading ? "Loading voices…" : "Load your voices to choose one.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Voice", selection: Binding(
                        get: { appState.selectedVoiceID ?? "" },
                        set: { appState.selectedVoiceID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("None — text only").tag("")
                        ForEach(shown) { voice in
                            Text(voice.accent.map { "\(voice.name) — \($0)" } ?? voice.name)
                                .tag(voice.voiceID)
                        }
                    }
                }

                Toggle("British accents only", isOn: $britishOnly)
                    .disabled(voices.isEmpty)
            }

            Section {
                HStack {
                    Button(isLoading ? "Loading…" : "Load voices") {
                        Task { await load() }
                    }
                    .disabled(isLoading)

                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Last turn") {
                Text(appState.lastLatencySummary ?? "No turn yet.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .task {
            if voices.isEmpty { await load() }
        }
    }

    private func load() async {
        guard let key = try? appState.keychain.get(.elevenLabsAPIKey), !key.isEmpty else {
            status = "Add an ElevenLabs key first."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await ElevenLabsClient(apiKey: key).voices()
            voices = fetched.sorted { $0.name < $1.name }
            status = "\(fetched.count) voices."
            // Nothing chosen yet: default to the first British voice so the
            // first turn can actually speak.
            if appState.selectedVoiceID == nil {
                appState.selectedVoiceID = shown.first?.voiceID
            }
        } catch {
            status = error.localizedDescription
        }
    }
}
