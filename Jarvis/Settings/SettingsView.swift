import SwiftUI
import KeyboardShortcuts
import JarvisBrain

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            APIKeysView()
                .tabItem { Label("API Keys", systemImage: "key") }
            VoiceSettingsView()
                .tabItem { Label("Voice", systemImage: "waveform") }
            ConnectorsView()
                .tabItem { Label("Connectors", systemImage: "app.connected.to.app.below.fill") }
            ActivitySettingsView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            PermissionsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        // No fixed width: the hosting window sizes this. Constraining it
        // here squeezed the tab bar into an overflow menu, which hid
        // API Keys entirely. The minimum has to clear all six tabs, or the
        // bar collapses to a "»" chevron and none of them are reachable.
        .frame(minWidth: 740, minHeight: 420)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        Form {
            Section("Model") {
                Picker("Answers with:", selection: $appState.modelTier) {
                    ForEach(ModelTier.allCases, id: \.self) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                Text("Haiku answers in about a second; Sonnet takes roughly twice "
                     + "as long but reasons better. Measured on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Interrupting") {
                Toggle("Let me talk over JARVIS", isOn: $appState.bargeInEnabled)
                if appState.bargeInEnabled {
                    Slider(value: $appState.bargeInSensitivity, in: 0...1) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("Raised voice").font(.caption2)
                    } maximumValueLabel: {
                        Text("Hair trigger").font(.caption2)
                    }
                    Text("On speakers JARVIS can hear itself and cut its own sentence off. "
                         + "If that happens, drag left. Headphones avoid it entirely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Activation") {
                KeyboardShortcuts.Recorder("Push to talk (hold) / toggle (tap):", name: .pushToTalk)
                KeyboardShortcuts.Recorder("Panic (cancel everything):", name: .panic)
            }
            Section {
                Text("Default panic key is ⌥⎋. ⌘⌥⎋ is macOS Force Quit, so avoid binding that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
    }
}
