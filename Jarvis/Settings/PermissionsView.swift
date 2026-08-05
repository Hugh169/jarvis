import SwiftUI
import AVFoundation
import Speech
import EventKit
import Contacts
import ApplicationServices

/// Live status for every permission the app needs, with deep links into
/// System Settings. Grants reset on every rebuild (they're tied to the code
/// signature), so this screen earns its keep during development.
@MainActor
struct PermissionsView: View {
    struct Item: Identifiable {
        let id: String
        let name: String
        let granted: Bool?   // nil = not yet requested
        let settingsAnchor: String
    }

    @State private var items: [Item] = []

    var body: some View {
        Form {
            Section("Permissions") {
                ForEach(items) { item in
                    HStack {
                        statusIcon(for: item.granted)
                        Text(item.name)
                        Spacer()
                        Button("Open Settings") { open(anchor: item.settingsAnchor) }
                            .buttonStyle(.link)
                    }
                }
            }
            Section {
                Button("Refresh") { refresh() }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .onAppear(perform: refresh)
    }

    private func statusIcon(for granted: Bool?) -> some View {
        Image(systemName: granted == true ? "checkmark.circle.fill"
              : granted == false ? "xmark.circle.fill" : "questionmark.circle")
            .foregroundStyle(granted == true ? .green : granted == false ? .red : .secondary)
    }

    private func open(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        items = [
            Item(
                id: "mic",
                name: "Microphone",
                granted: granted(from: AVCaptureDevice.authorizationStatus(for: .audio)),
                settingsAnchor: "Privacy_Microphone"
            ),
            Item(
                id: "speech",
                name: "Speech Recognition",
                granted: grantedSpeech(SFSpeechRecognizer.authorizationStatus()),
                settingsAnchor: "Privacy_SpeechRecognition"
            ),
            Item(
                id: "accessibility",
                name: "Accessibility",
                granted: AXIsProcessTrusted(),
                settingsAnchor: "Privacy_Accessibility"
            ),
            Item(
                id: "screen",
                name: "Screen Recording",
                granted: CGPreflightScreenCaptureAccess(),
                settingsAnchor: "Privacy_ScreenCapture"
            ),
            Item(
                id: "calendars",
                name: "Calendars",
                granted: grantedEventKit(EKEventStore.authorizationStatus(for: .event)),
                settingsAnchor: "Privacy_Calendars"
            ),
            Item(
                id: "reminders",
                name: "Reminders",
                granted: grantedEventKit(EKEventStore.authorizationStatus(for: .reminder)),
                settingsAnchor: "Privacy_Reminders"
            ),
            Item(
                id: "contacts",
                name: "Contacts",
                granted: grantedContacts(CNContactStore.authorizationStatus(for: .contacts)),
                settingsAnchor: "Privacy_Contacts"
            ),
        ]
    }

    private func granted(from status: AVAuthorizationStatus) -> Bool? {
        switch status {
        case .authorized: true
        case .denied, .restricted: false
        default: nil
        }
    }

    private func grantedSpeech(_ status: SFSpeechRecognizerAuthorizationStatus) -> Bool? {
        switch status {
        case .authorized: true
        case .denied, .restricted: false
        default: nil
        }
    }

    private func grantedEventKit(_ status: EKAuthorizationStatus) -> Bool? {
        switch status {
        case .fullAccess, .writeOnly: true
        case .denied, .restricted: false
        default: nil
        }
    }

    private func grantedContacts(_ status: CNAuthorizationStatus) -> Bool? {
        switch status {
        case .authorized, .limited: true
        case .denied, .restricted: false
        default: nil
        }
    }
}
