# JARVIS — macOS voice assistant

Native macOS voice assistant: hold ⌥Space, speak, Claude answers in a British
voice (ElevenLabs) and executes tools on the machine. The full spec lives in
the build plan; work proceeds in phases (currently: **Phase 4 — tools**).

## Layout

- `Jarvis/` — app-target sources (SwiftUI menu bar, HUD `NSPanel`, hotkeys, settings).
- `Packages/` — seven local SPM packages (Core, Audio, Speech, Voice, Brain, Tools, Memory).
  Rule: every package builds and tests independently of the app target.
- `Package.swift` (root) — convenience manifest building the app as a plain
  executable (`JarvisDev`) for a fast no-bundle loop. Not the shipping app.
- `project.yml` — XcodeGen manifest for the real app bundle (entitlements,
  Info.plist, Hardened Runtime).
- `design/jarvis-hud.dc.html` — the design the HUD implements (Claude Design
  export). Colours there are authored in OKLCH; `HUDTheme` carries the exact
  sRGB conversions.

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
- **One accent.** Cyan is the identity: listening, working, and the ambient
  chrome. Amber means one thing only — needs your go-ahead. Green is a
  completed tool, red a failed one.
- **Chrome carries no state.** The reticle corners and the halo look the same
  whatever is happening; only the scan sweep tracks a state, and it reinforces
  the glyph rather than being the sole signal.
- Always dark (`.environment(\.colorScheme, .dark)`) since it floats over
  arbitrary desktops.

`HUDDemo` drives a full turn — transcript, tool chips, reply, detail pane — with
no audio, network, or tools, via the menu bar or `--demo-turn`. It goes through
`beginSimulatedListening()`, *not* `beginListening()`: the latter opens the real
microphone, so the demos used to transcribe the room over their own script.

Two things from the reference could not be reproduced as written. The rotating
conic halo relies on blurring a gradient, and `.blur()` has no pixels to sample
beyond the layer edge in a transparent borderless window — it renders as a hard
rectangle with ragged edges. The glow is built from stacked shadows instead,
which composite cleanly. And the panel scrim is denser than the reference's
0.74, because AppKit's `.ultraThinMaterial` blurs far less than CSS
`backdrop-filter: blur(40px)`; at the reference value the window behind stays
legible through the panel.

## Toolchain requirement

**The app target needs full Xcode** (installed and selected — Xcode 26.6 is).
SwiftUI's `@State` and `#Preview` are macros whose plugins (`SwiftUIMacros`,
`PreviewsMacros`) ship only with Xcode; the Command Line Tools carry just
Observation, Swift, and Testing macros, so under CLT alone *every* SwiftUI file
fails to compile, including KeyboardShortcuts'.

Two one-time setup steps, both done on this machine:
`sudo xcodebuild -license accept` and `xcodebuild -runFirstLaunch`.

The seven packages have no SwiftUI dependency; `scripts/test.sh` falls back to
the CLT toolchain automatically, so they test even if the licence lapses.

**`swift run JarvisDev` does not give you a usable app.** An unbundled binary
isn't registered with LaunchServices, so `MenuBarExtra` has nothing to attach to
and no menu bar icon appears. Always build the `.app`.

## Interaction

| | |
|---|---|
| ⌥Space | Push to talk (hold), or tap to toggle. Mid-reply it interrupts. |
| ⌥⇧Space | Type instead of speaking. |
| Escape | Dismiss, at any point in a turn. |
| ⌥Escape | Panic — cancel everything. |

Escape is a *global* hotkey, so it is registered only while the HUD is on screen
and unregistered the moment it hides. Leaving it installed would swallow Escape
in every other app.

Typing requires the HUD panel to become key, which a `.nonactivatingPanel`
normally refuses. `HUDPanel.acceptsTyping` flips `canBecomeKey`, and the panel
must be ordered on screen *before* it can be made key — setting the flag alone
leaves the field visible but inert, with keystrokes going to the app behind.

After a reply the microphone reopens for five seconds so a follow-up needs no
hotkey. History already carried context across turns; this only removes the
keypress. Both listening modes have a no-speech timeout — the VAD reports the
*end* of speech, which needs a start, so without one an open mic and a silent
room waited forever.

## Commands

```sh
./scripts/test.sh                    # all package tests
./scripts/setup-signing.sh           # once: stable local signing identity
./scripts/run.sh                     # generate, build the .app, install, launch
./scripts/run.sh --demo-turn         # ...and run the HUD demo turn
./scripts/run.sh --say "hello"       # ...and run a real turn from text, no mic
tail -f ~/.jarvis/debug.log          # turn tracing and latency (spec §12)
```

## Code signing and the Keychain

API keys live in the Keychain, and the Keychain grants access **per code
signature**. Ad-hoc signing mints a new identity every build, so macOS treats
each rebuild as an unknown app and blocks the first key read behind an approval
dialog — every single time, and a turn just stalls until it's answered.

`scripts/setup-signing.sh` creates a stable self-signed identity ("Jarvis Local
Dev", trusted in the user domain, no admin rights needed) and `run.sh` picks it
up automatically. Approve the Keychain prompt once with **Always Allow** and it
stops asking. Local development only — not a Developer ID, cannot be
distributed.

`--demo-turn` / `--demo-confirmation` are launch arguments on the app itself,
so the UI can be exercised deterministically without going through the menu.

Entitlements are generated **from `project.yml`** — `xcodegen` overwrites
`Jarvis.entitlements` on every run, so edit the YAML, never the plist.

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

1. ✅ Skeleton: packages, menu bar, HUD, hotkeys, Keychain settings, panic key.
   48 package tests pass; the app builds, installs, and runs. Verified on screen:
   menu bar icon and menu, ⌥Space toggling the HUD, and a full demo turn
   rendering transcript → tool chips (with real app icons and live timings) →
   reply → detail pane. Not yet verified: HUD over a *full-screen* app.
2. 🟡 Voice loop — built and wired: `AudioCapture` (mic + RMS), `AppleTranscriber`
   (on-device `SpeechAnalyzer`), `AnthropicClient` (SSE streaming),
   `ElevenLabsClient` (Flash v2.5 over WebSocket, `pcm_24000`), `PlaybackQueue`,
   sentence pipelining via `SentenceChunker`, and `TurnMetrics`. Verified on the
   wire that Claude streams and replies in persona. **Not yet verified
   end-to-end**: audible speech, and the < 1.2s end-of-speech → first-audio
   budget. Blocked only on approving Keychain access once.

   Deviation: deployment target raised to macOS 26 (from 15). `SpeechAnalyzer`
   requires it, and the spec's `SFSpeechRecognizer` fallback existed only for
   older systems this Mac isn't.
3. 🟡 Latency + barge-in. Sentence pipelining, WebSocket TTS and the PCM
   playback queue landed in Phase 2. Barge-in is now built: the mic tap stays
   live through thinking and speaking (`CaptureRouter` routes buffers by turn
   state), a less sensitive `EnergyVAD.Configuration.bargeIn` watches for the
   user talking over JARVIS, and a hit cuts playback, cancels the in-flight
   model stream and TTS socket, and opens a fresh utterance.

   **Unverified end-to-end** — it only engages on a spoken turn, and the
   `--say` harness never opens the mic. Needs a human to interrupt it.

   Known limits: the word or two that triggers detection is lost (a rolling
   pre-roll buffer would recover it), and on speakers JARVIS can hear itself
   and cut its own sentence off — hence the sensitivity slider in Settings.
4. 🟡 Tools. Tier 1 tools (reminders, calendar, weather, apps, Spotlight, scoped
   files, clipboard, volume, URLs, shortcuts, `display_detail`,
   `request_confirmation`), the tool-use loop with concurrent execution and an
   8-round cap, the confirmation gate, and the JSONL audit log.

   Acceptance **passed**: "Remind me to submit the physics prac at 4pm tomorrow,
   and what's the weather tomorrow?" ran `create_reminder` and `get_weather`
   concurrently in one turn, both succeeding.

   Deviation: `get_weather` uses Open-Meteo, not WeatherKit — WeatherKit needs an
   entitlement tied to a registered App ID and a paid Apple Developer account,
   impossible for a self-signed local build. Swapping back replaces one
   `execute`.

   **Unverified**: a deliberate approve/decline click on the gate. It provably
   holds and waits, but see "The HUD steals clicks" below.
   **Layer 1 — live search and location** (added after Phase 4; Phase 5 memory
   and the MCP client are deferred).

   ✅ **Web search.** Anthropic's server-side tool: declared in the request,
   never executed here, results arriving as content blocks in the same
   response. Verified on the wire — a "news today" turn ran the search and
   answered from it in 399 characters.

   🔴 **Location and directions.** `where_am_i`, `travel_time_to`,
   `directions_to`, `nearby` — CoreLocation and MapKit, no key or OAuth. They
   compile, register and are covered by tests, but **do not work on this
   build**: see below.

5–9. ⬜ Memory, AppleScript/shell, MCP, computer use, polish.

## Server-side tools change the shape of a turn

Web search doesn't behave like the other tools, and three things had to change
to carry it:

- **The tool version follows the model.** `web_search_20260209` (the variant
  that filters results with code before they hit the context window) is a 400
  on Haiku 4.5 — which is the tier chosen for latency. `ModelTier.webSearchVersion`
  falls back to the basic `web_search_20250305` there. Hardcoding either one
  breaks half the tiers.
- **Server blocks must survive the round trip.** `server_tool_use` and
  `web_search_tool_result` are echoed back verbatim in the assistant turn, or
  the model loses the results it just fetched. Text also resumes *after* a
  search, so the assistant turn is rebuilt in arrival order rather than
  text-then-tools.
- **`pause_turn` is not the end of a turn.** The server-side search loop has its
  own iteration cap; hitting it ends the response early, and it resumes by
  re-sending with the partial assistant turn appended and *no* new user
  message. It has its own budget (`maxContinuations`) rather than eating tool
  rounds.

A failed search is still HTTP 200 and still a well-formed block — `content`
comes back as a single error object rather than the usual array. Code that
assumes an array reads that as a crash.

Block assembly lives in `StreamAssembler`, not `AnthropicClient`, so it can be
tested against the bytes the API actually sends instead of against a copy of the
logic in the test file.

A searching turn costs seconds: measured 4.2s to first audio against a 1.2s
budget. That is inherent — there is a full round trip before the first token —
and the budget only applies to turns that don't search.

## Location never gets asked for

`where_am_i` and the travel tools are written and tested but return an error on
this build. The chain of evidence, so nobody repeats it:

- Location Services is **on** globally, and the app's status is
  `notDetermined` — reported by the tool itself in the audit log, which is why
  `LocationError.timedOut` carries the authorisation state.
- No prompt ever appears, and **`locationd` and `tccd` never log the request at
  all**. It isn't a denial; the request never reaches the daemon.
- `CLLocationUpdate.liveUpdates()` was the first attempt and is worse than
  useless here: on macOS it never requests authorisation, so it produces
  nothing, forever, with no error. It needs an explicit `CLLocationManager`.
- `requestWhenInUseAuthorization()` is an iOS concept — macOS has only *Always*
  — so the call is a silent no-op. `requestAlwaysAuthorization()` is correct
  and still produces nothing.
- All three usage-description keys are present in the built Info.plist.

Untested hypotheses, in the order worth trying: the app is `LSUIElement` with
`.accessory` activation policy and never becomes frontmost, which historically
blocks location prompts; or `locationd` is refusing a self-signed identity that
isn't a Developer ID.

Until it's resolved the tools fail in three seconds with something the user can
act on, rather than making every turn wait out the twelve-second fix timeout.

## The HUD steals clicks

The HUD floats at top-centre, which is exactly where app toolbars, tab bars and
address bars live. It is `ignoresMouseEvents` while merely showing status, so
clicks pass through to whatever is underneath — but it *must* accept clicks
while a confirmation is up, and a click aimed at the window below then lands on
the confirmation instead.

This was observed for real: repeated writes were approved during testing purely
because clicks in Safari were landing on the HUD's approve button. Mitigations
so far: click-through unless a decision is pending, and approve stays inert for
450ms so an in-flight click can't authorise anything (Cancel is live at once —
the safe answer never needs protecting).

Residual risk remains: a deliberate click 2s later still hits it. If this bites,
the options are moving confirmations off the top-centre strip, or promoting them
to a real focused window.
