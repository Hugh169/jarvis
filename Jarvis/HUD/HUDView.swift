import SwiftUI
import JarvisCore

/// Phase 1 HUD: state indicator only. Waveform, streaming transcript, reply
/// text, and tool chips arrive with the voice loop.
struct HUDView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 14) {
            stateIndicator
            VStack(alignment: .leading, spacing: 4) {
                Text("JARVIS")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(appState.turnState.displayName)
                    .font(.title3.weight(.medium))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .preferredColorScheme(.dark)
    }

    private var stateIndicator: some View {
        Image(systemName: appState.turnState.menuBarSymbol)
            .font(.system(size: 28))
            .foregroundStyle(appState.turnState == .listening ? .red : .secondary)
            .symbolEffect(.pulse, isActive: appState.turnState != .idle)
            .frame(width: 36)
    }
}
