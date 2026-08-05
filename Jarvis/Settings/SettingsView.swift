import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            APIKeysView()
                .tabItem { Label("API Keys", systemImage: "key") }
            PermissionsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480)
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Form {
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
