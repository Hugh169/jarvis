# JARVIS

A native macOS voice assistant. Hold ⌥Space, speak, and Claude answers in a
British voice and actually does things on the machine — creates reminders,
checks the calendar and weather, opens apps, searches files, runs Shortcuts.

Siri's interaction model, Claude's brain, real tool execution.

Personal software, built for one Mac. It can't ship on the App Store — App
Sandbox is off by necessity, because automating other apps and running shell
commands are incompatible with it.

## How it works

```
⌥Space ─► microphone ─► on-device speech ─► Claude (streaming) ─► ElevenLabs ─► speakers
                                               │
                                               └─► tools ─► Reminders, Calendar,
                                                            Weather, Finder, Shortcuts…
```

Everything is subordinate to latency. Sentences are pushed to text-to-speech as
the model produces them, so audio starts while Claude is still writing; waiting
for the full reply would blow the budget on its own. The target is under 1.2
seconds from end-of-speech to the first spoken syllable, and each turn logs
where its time went.

The interface is a single floating panel, not a chat window. It shows what was
heard, which apps are being driven right now — with their real icons — and the
reply. Anything long or structured goes on screen instead of being read aloud.

You can talk over it. The microphone stays live while JARVIS speaks, and
interrupting cuts the audio and starts a new turn.

## Layout

| | |
|---|---|
| `Jarvis/` | App target — menu bar, HUD panel, hotkeys, settings |
| `Packages/JarvisCore` | Turn state machine, Keychain, metrics |
| `Packages/JarvisAudio` | Capture, voice activity detection, playback queue |
| `Packages/JarvisSpeech` | On-device transcription |
| `Packages/JarvisVoice` | ElevenLabs streaming client, sentence chunker |
| `Packages/JarvisBrain` | Anthropic Messages API, SSE, system prompt |
| `Packages/JarvisTools` | Tool implementations, audit log |
| `Packages/JarvisMemory` | Persistence (in progress) |

Every package builds and tests independently of the app.

## Building

Needs macOS 26+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
./scripts/setup-signing.sh   # once — a stable local signing identity
./scripts/run.sh             # generate, build, install to /Applications, launch
./scripts/test.sh            # all package tests
```

Then add an Anthropic key and an ElevenLabs key in Settings. They go to the
Keychain and nowhere else.

The signing step matters more than it looks: Keychain access is granted per code
signature, and ad-hoc signing mints a new identity on every build, so without a
stable identity macOS re-asks for permission every time you rebuild.

## Safety

Destructive tools are gated behind a confirmation in the HUD. File access is
limited to `~/Documents`, `~/Desktop`, `~/Downloads` and `~/Developer`, with
path traversal blocked and tested. Every tool call is recorded to
`~/.jarvis/audit.log` as JSONL — arguments, outcome, duration, and whether it
was confirmed. There's a dry-run mode that describes what each tool would do
without doing it, and a panic key (⌥Esc) that cancels everything.

## Status

Working: the voice loop, barge-in, and the first tier of native tools with the
tool-use loop, confirmation gate and audit log.

Next: persistent memory, an AppleScript bridge, an MCP client, and computer use.

Development notes, measured latency figures and known rough edges are in
[CLAUDE.md](CLAUDE.md).
