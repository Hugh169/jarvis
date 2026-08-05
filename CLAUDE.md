# JARVIS — macOS voice assistant

Native macOS voice assistant: hold ⌥Space, speak, Claude answers in a British
voice (ElevenLabs) and executes tools on the machine. The full spec lives in
the build plan; work proceeds in phases (currently: **Phase 1 — skeleton**).

## Layout

- `Jarvis/` — app-target sources (SwiftUI menu bar, HUD `NSPanel`, hotkeys, settings).
- `Packages/` — seven local SPM packages (Core, Audio, Speech, Voice, Brain, Tools, Memory).
  Rule: every package builds and tests independently of the app target.
- `Package.swift` (root) — convenience manifest building the app as a plain
  executable (`JarvisDev`) for a fast no-bundle loop. Not the shipping app.
- `project.yml` — XcodeGen manifest for the real app bundle (entitlements,
  Info.plist, Hardened Runtime).

## Toolchain requirement

**The app target needs full Xcode.** SwiftUI's `@State` and `#Preview` are
macros whose plugins (`SwiftUIMacros`, `PreviewsMacros`) ship only with Xcode —
the Command Line Tools carry just Observation, Swift, and Testing macros. Under
a CLT-only toolchain *every* SwiftUI file fails to compile, including
KeyboardShortcuts'. Fix: install Xcode, then
`sudo xcode-select -s /Applications/Xcode.app`.

The seven packages have no SwiftUI dependency and build and test on CLT alone.

## Commands

```sh
./scripts/test.sh               # all package tests (works on CLT; see script for flag rationale)
swift build                     # compile everything incl. app sources (needs Xcode)
swift run JarvisDev             # run the menu bar app unbundled (needs Xcode; no TCC perms)
xcodegen generate               # emit Jarvis.xcodeproj from project.yml (needs Xcode)
```

## Constraints (from the spec — do not regress)

- App Sandbox OFF; Hardened Runtime ON with allow-jit, disable-library-validation,
  automation.apple-events.
- API keys only in the Keychain (`JarvisCore.KeychainStore`).
- Latency is the product: target < 1.2 s end-of-speech → first audio.
- Everything destructive requires confirmation (`JarvisTool.requiresConfirmation`).
- Swift 6 strict concurrency; no `[String: Any]` in networking (use `JSONValue`).
- Model routing: Sonnet 5 default, Haiku 4.5 for background jobs, Opus 5 for
  deep/computer-use turns (`JarvisBrain.ModelTier`).

## Known deviations from the spec

- Panic hotkey defaults to ⌥Esc, not ⌘⌥Esc — the latter is the system Force
  Quit shortcut and can't be cleanly claimed. Rebindable in Settings.

## Phase status

1. 🟡 Skeleton: packages, menu bar, HUD, hotkeys, Keychain settings, panic key —
   all written; the seven packages compile and pass 38 tests. The acceptance
   criterion (⌥Space shows/hides the HUD over a full-screen app) is **unverified**
   because the app target cannot compile without Xcode (see Toolchain
   requirement). Install Xcode, then `swift build` and run to confirm.
2. ⬜ Voice loop (mic → Apple STT → Claude streaming → ElevenLabs Flash v2.5).
3. ⬜ Latency + barge-in.
4. ⬜ Tier 1 tools + tool loop + confirmation gate + audit log.
5–9. ⬜ Memory, AppleScript/shell, MCP, computer use, polish.
