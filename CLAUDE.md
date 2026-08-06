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
- `design/hud-mockup.html` — interactive mockup of the HUD (every state, no
  toolchain needed). Open it directly in a browser; it is the reference the
  SwiftUI in `Jarvis/HUD/` implements.

## HUD design

The HUD is the whole interface — there is no chat window. One panel pinned
top-centre, growing downward from a fixed top edge through three zones that
appear only when they have content: what you said, which apps are being driven
now, and the reply. Rules it follows:

- **Two channels.** Spoken text stays to one or two sentences; anything
  structured goes to the detail pane via `display_detail`.
- **Real app icons.** `ToolPresentation` maps a tool name to a bundle id and
  `AppIconLoader` pulls the actual icon from `NSWorkspace`, so you can see at a
  glance which apps were touched. Unknown tools (MCP included) fall back to a
  humanised name and an SF Symbol.
- **Typeface encodes source.** Speech in the UI face, tool names and timings in
  monospace.
- **One accent.** Brass carries "working"; red is reserved for a hot mic and
  failures; green only for a completed tool.
- Always dark (`.environment(\.colorScheme, .dark)`) since it floats over
  arbitrary desktops.

`HUDDemo` drives a full turn — transcript, tool chips, reply, detail pane — with
no audio, network, or tools, via the menu bar. Use it to exercise the UI until
Phase 2 lands.

## Toolchain requirement

**The app target needs full Xcode** (installed and selected — Xcode 26.6 is).
SwiftUI's `@State` and `#Preview` are macros whose plugins (`SwiftUIMacros`,
`PreviewsMacros`) ship only with Xcode; the Command Line Tools carry just
Observation, Swift, and Testing macros, so under CLT alone *every* SwiftUI file
fails to compile, including KeyboardShortcuts'.

Xcode's licence must be accepted once before any build works:

```sh
sudo xcodebuild -license accept
```

The seven packages have no SwiftUI dependency; `scripts/test.sh` falls back to
the CLT toolchain automatically, so they test even while the licence is pending.

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
   all written; the seven packages compile and pass 48 tests. The acceptance
   criterion (⌥Space shows/hides the HUD over a full-screen app) is **unverified**
   — the app target has never been compiled, pending the Xcode licence above.
   First run after that: `swift build`, then exercise the HUD via the menu bar's
   demo items.
2. ⬜ Voice loop (mic → Apple STT → Claude streaming → ElevenLabs Flash v2.5).
3. ⬜ Latency + barge-in.
4. ⬜ Tier 1 tools + tool loop + confirmation gate + audit log.
5–9. ⬜ Memory, AppleScript/shell, MCP, computer use, polish.
