# JARVIS — macOS voice assistant

Native macOS voice assistant: hold ⌥Space, speak, Claude answers in a British
voice (ElevenLabs) and executes tools on the machine. The full spec lives in
the build plan; work proceeds in phases (currently: **Phase 4 — tools**).

## Layout

- `Jarvis/` — app-target sources (SwiftUI menu bar, HUD `NSPanel`, hotkeys, settings).
- `Packages/` — eight local SPM packages (Core, Audio, Speech, Voice, Brain,
  Tools, Memory, Connectors).
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

   **Unverified**: a deliberate approve/decline click. The gate provably holds
   and waits, and the window it now waits in is verified on screen — but the
   Keychain prompt lands on top of it on every rebuild, so the click itself
   still needs a human. See "Confirmations are a window" below.
   **Layer 1 — live search and location** (added after Phase 4; Phase 5 memory
   and the MCP client are deferred).

   ✅ **Web search.** Anthropic's server-side tool: declared in the request,
   never executed here, results arriving as content blocks in the same
   response. Verified on the wire — a "news today" turn ran the search and
   answered from it in 399 characters.

   ✅ **Location and directions.** `where_am_i`, `travel_time_to`,
   `directions_to`, `nearby` — CoreLocation and MapKit, no key or OAuth.
   Verified in a real turn: a fix in 460ms and five travel lookups, all
   succeeding. It was blocked for a while and the diagnosis is kept below,
   because the two dead ends are easy to walk back into.

   ✅ **Google connectors.** OAuth inside the app — calendar and Gmail tools,
   verified end to end against a real account.

   ✅ **Visual answers.** A timeline for anything with times, and `display_cards`
   for everything else — facts, figures, tables, maps, photos. Drawn without
   asking the model to choose; see "The model will not call a display tool".

5–9. ⬜ Memory, AppleScript/shell, MCP, computer use, polish.

## Open, in the order I'd take them

- **The Keychain prompt reappears on most rebuilds**, asking for the login
  password rather than a plain Allow, which means the ACL isn't binding to the
  signing identity. It is not cosmetic: it has blocked turns, hidden UI during
  verification, and distorted latency measurements badly enough to make a
  change look like a 2× regression when it wasn't.
- **The model narrates before tool calls** — "I'll check your calendar…" — and
  it is spoken aloud. The prompt forbids it and Haiku does it anyway. The HUD
  no longer displays it. Suppressing it properly means not speaking text from
  rounds that end in a tool call, which costs the streaming the 1.2s budget
  depends on; Sonnet holds the instruction better.
- **Phase 5 (memory)** is the largest thing not started, and the one that
  changes what the product is: it currently forgets everything between
  launches.

## Google connectors belong to the app, not to macOS

Nothing is registered with Internet Accounts, so no other app on this Mac can
see or use the grant. The refresh token is a Keychain item of JARVIS's; the
access token stays in memory and never reaches disk.

- **Loopback redirect, PKCE, POSIX sockets.** Google removed the out-of-band
  flow, so the app has to catch the redirect itself. Network.framework can't:
  *every* `NWListener` configuration fails here with `EINVAL` before reaching
  `.ready`, including a bare `NWListener(using: .tcp)` — confirmed outside the
  sandbox, so it isn't a permissions artefact. `socket`/`bind`/`listen` works
  first time. Non-loopback peers are refused at accept time.
- **Scopes are least privilege**: `calendar.events`, `gmail.readonly`,
  `gmail.compose`. Nothing that can delete. Google has no draft-only scope, so
  `send_mail` is gated behind the confirmation prompt in the tool layer.
- **Consent-screen audience decides everything.** *Internal* (Workspace domain)
  means the grant never expires. *External* expires refresh tokens after seven
  days, needs test users, and needs Google verification to escape — `readonly`
  is a restricted scope. This project is Internal.
- Mail is the canonical untrusted input: anyone can send you some, and it flows
  into a model that runs tools on this machine. Nothing here acts on what it
  reads.

### Never read the Keychain on a hot path

`SecItemCopyMatching` blocks for as long as the approval dialog is up, and if
it's called from inside an actor every queued request waits behind it.
`GoogleAccount` originally read the refresh token on *every* API call, which
made a three-message mail search take sixteen seconds — and made fetching the
messages concurrently *slower* than doing them one at a time, because the extra
concurrency only piled up behind the same blocking read. The token is cached in
the actor after the first read now. `KeychainStore.value(for:)` is the async,
off-main accessor and is what any repeated read should use.

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

## Location: two dead ends worth not repeating

The travel tools work now. They didn't for a while, and both wrong turns look
completely reasonable from the code:

- **`CLLocationUpdate.liveUpdates()` never requests authorisation on macOS.**
  It is the tidier API and it simply produces nothing, forever, with no error
  and nothing in the log. It needs an explicit `CLLocationManager`.
- **`requestWhenInUseAuthorization()` is an iOS concept.** macOS has only
  *Always*, so the call is a silent no-op — no prompt, no callback, status
  stays `notDetermined`. `requestAlwaysAuthorization()` is the one.

The symptom of both is identical and gives you nothing: a twelve-second timeout
and no prompt. `LocationError.timedOut` carries the authorisation state for
exactly this reason, and it is what eventually made the cause visible. If it
ever goes quiet again, check `locationd` and `tccd` in `log show` **first** —
if neither has seen the request, the problem is upstream of permissions and no
amount of staring at the code will show it.

The original chain of evidence follows.

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

## The model will not call a display tool. Stop asking it.

This cost a lot of iterations, so it is written down. `display_schedule`
survived a rule in the system prompt, the trigger spelled out prescriptively in
the tool's own description, *and* an instruction attached to the tool result at
the exact moment of the decision — and Haiku read the day aloud item by item
every time regardless.

Two fixes, both of which take the choice away:

- **Where a tool already has the data, draw it.** `list_events` returns
  structured events and hands them to the HUD itself. Consult the calendar,
  get a timeline.
- **Where only the model has the answer, force it.** `Visualiser` makes a
  second cheap Haiku call after the reply with `tool_choice` set to
  `display_cards`; the API will not let it return anything else. It runs while
  JARVIS is speaking, so it costs nothing on the latency budget — the panel
  fills in under the sentence in the air.

The corollary: **do not add more display tools.** More options make this worse,
not better. `display_cards` composes a page out of blocks (facts, stat, list,
table, note, map, image) precisely so there is one call to make.

Blocks are parsed leniently — a block missing what its type needs is dropped
rather than failing the call, because losing a row beats the model getting an
error and reading the answer aloud. Two exceptions, both about not putting
nonsense on screen: coordinates at Null Island or out of range are rejected
(the signature of a required field filled in by guesswork), and images must be
`https` with a real host, since that is the only content in this app fetched
from wherever the model says.

Maps are `MKMapSnapshotter` stills, not live map views: the panel ignores mouse
events so nothing could be panned anyway, and a live map renders gesture and
attribution furniture with nowhere to go. Forced to dark — the HUD is always
dark, and a daylight map in it looks like a hole punched in the panel. Note the
type is `MapPlace`; `MapPin` is ambiguous against MapKit's own.

## Two channels, and one of them is drawn

`display_detail` can only ever produce words, so anything with a shape read as
a wall of text. `display_schedule` is the second visual channel: the assistant
hands over what happens and when, and `ScheduleView` draws it — time gutter,
a rail with a node per event, travel legs as dashed connectors carrying a mode
glyph and minutes, clashes in amber. The assistant chooses the form, which is
why it's a separate tool rather than a rendering mode on the old one.

Amber still means exactly one thing: this needs your attention. On a timeline
that's an overlap; everywhere else it's a confirmation.

`MarkdownBlocks` renders the detail pane. `AttributedString(markdown:)` keeps
block structure only as a `presentationIntent` that `Text` ignores, so "##
Your Week Ahead" rendered with its hashes showing. It deliberately does **not**
fold consecutive lines the way markdown does — the assistant writes a fact per
line here, and folding runs them into a sentence nobody wrote.

## The panel must never be asked to squeeze

The window's height follows the view's reported height, so while it catches up
the height proposal can be smaller than the content needs — and SwiftUI's
answer to too little room is to compress. That is what put the "Working" label
on top of a long transcript. `.fixedSize(horizontal: false, vertical: true)` on
the root makes the content refuse to shrink; the window catches up a frame
later.

Long transcripts are capped at three lines. You just said it — three lines
confirms it was heard, and the rest of the panel is for the answer.

**The detail pane cannot scroll.** Not an oversight: the panel is
`ignoresMouseEvents` so it doesn't steal clicks aimed at whatever is beneath
it, and that makes it scroll-through as well — the wheel never arrives. Making
it scrollable means accepting mouse events, which is the exact behaviour the
click-through rule exists to prevent. Content renders at full height instead.

## Confirmations are a window, not part of the HUD

The HUD floats at top-centre, which is exactly where app toolbars, tab bars and
address bars live. That was survivable while it only showed status — it is
`ignoresMouseEvents`, so clicks pass through — but a confirmation *must* accept
clicks, and a click aimed at the window below then landed on the approve button.

This was observed for real: repeated writes were approved during testing purely
because clicks in Safari were hitting the HUD. Click-through-unless-pending and
a 450ms inert approve reduced it without fixing it, because the panel was in the
wrong place and the user had never chosen to interact with it.

Confirmations now open their own window (`ConfirmationWindowController`),
centred, focused, above the HUD's level. The HUD keeps a passive notice saying
where to answer and carries no buttons at all — so it is now click-through
except when you are typing into it, and the whole class of stolen-click
approvals is gone. Two mitigations are kept because the window still appears
unbidden and takes focus: approve is inert for 450ms, and approve is **⌘Return,
never plain Return** — a Return already on its way to your own app must not
authorise anything, which is the click bug one device over. Escape cancels.
The close button is hidden: nothing dismisses this except an answer, since
anything else leaves the tool call suspended.

It also shows the arguments as rows rather than one 80-character-clipped line.
For `send_mail` the body is the part you most need to read before saying yes,
and unlike the HUD's detail pane this window accepts mouse events, so it can
scroll.

Two AppKit traps, both of which put a window on screen that isn't there:

- **`fittingSize` straight after setting `contentView` is zero** — layout hasn't
  run. The window was created, focused and 0×0. Use `contentViewController`
  with an `NSHostingController` and `layoutSubtreeIfNeeded()` before reading it.
- **Centring before layout divides by a width you don't have yet**, which put
  the window's left edge exactly on the middle of the screen. Size first, then
  centre.
