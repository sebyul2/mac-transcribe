<p align="center">
  <img src="./public/assets/readme/character.png" alt="Mac Whisper mascot" width="120">
</p>

<h1 align="center">Mac Whisper</h1>

<p align="center">
  <em>Hold ⌃Fn, speak, and paste clean dictation into the app you are using.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.0.3-111111?style=flat-square" alt="Version 0.0.3">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111?style=flat-square" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111111?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-5.9-111111?style=flat-square" alt="Swift 5.9">
</p>

<p align="center">
  <sub><a href="./README.md">English</a> &middot; <a href="./README.ko.md">한국어</a></sub>
</p>

<p align="center">
  <a href="https://github.com/spooncast/mac-whisper/releases/latest/download/MacWhisper.dmg"><img src="./public/assets/readme/download-macos.png" alt="Download MacWhisper.dmg for Mac OS" width="270"></a>
</p>

---

<p align="center">
  <img src="./public/assets/readme/mac-whisper-demo.gif" alt="Mac Whisper push-to-talk dictation demo" width="100%">
</p>

Mac Whisper is a macOS menu bar app for push-to-talk dictation. Hold ⌃Fn (or
the configurable trigger key), speak, release, and the transcript is pasted
into the text field that already has focus.

It also has a locked long-form recording mode for meetings: a hands-free
session that survives long silences and saves the transcript to a file instead
of the clipboard.

It can also run a conservative LLM cleanup pass before pasting. The cleanup is
optional, and the raw transcript is used if the LLM request fails.

> Built for writing in any app without switching windows, opening a recorder, or
> managing a separate transcript box.

**The app listens for the trigger keys through keyboard HID (plus NSEvent
flagsChanged, so modifier triggers keep working with Karabiner-Elements
installed), records with the Speech framework, shows a floating HUD while you
talk, and pastes through the clipboard with a simulated Cmd+V. It prefers the
built-in microphone during push-to-talk dictation so Bluetooth headphones can
stay in high quality playback mode.**

## Why this exists

macOS dictation works, but it is not tuned for quick push-to-talk writing across
every app. Mac Whisper keeps the flow simple:

- hold ⌃Fn (or the trigger key) to start
- release to stop
- see the live transcript while speaking
- paste into the focused text field
- optionally clean up recognition mistakes with an LLM

It is meant for short writing bursts: messages, notes, prompts, search boxes,
issue comments, and anywhere else your cursor already is. For anything longer —
a meeting, a lecture, a brainstorm — switch to the locked long-form mode and let
it run.

## Hotkeys

Bare Fn is **no longer** a trigger, so Fn+arrow / Fn+F-key combos can never
misfire a dictation session.

| Action | Apple keyboard | Any keyboard (configurable) |
|---|---|---|
| Push-to-talk | Hold ⌃Fn | Hold trigger key (default: Left Ctrl) |
| Long-form recording (toggle) | ⌃⇧Fn | Trigger + Shift (default: Left Ctrl+Shift), or an optional dedicated long-form key |

Both keys are configurable from the menu → `Trigger Key…` with press-to-capture
(click Change…, press the key you want). Modifier triggers work even with
Karabiner-Elements installed. If you press another key while holding the
trigger — using it as a plain modifier — the misfired dictation session is
canceled automatically.

## Status

| Area | Behavior | Notes |
|---|---|---|
| Trigger | Hold ⌃Fn or a configurable trigger key | Read from keyboard HID + NSEvent flagsChanged; Karabiner-compatible |
| Speech | Live streaming recognition | Supports English, Korean, Chinese, and Japanese |
| Long-form | Locked (meeting) recording | macOS 26 SpeechAnalyzer engine, tolerant of long silences |
| HUD | Floating transcript panel | Uses Liquid Glass on macOS 26 |
| Captions | Subtitle overlay + Transcript Window | Last two sentences at the bottom of the screen, close on hover |
| Audio | Built-in mic preference (push-to-talk) | Long-form uses the system default input and backs up raw audio |
| Paste | Clipboard plus Cmd+V | Restores the previous clipboard after 800 ms, guarded by changeCount |
| LLM | Optional cleanup | API-key providers or a ChatGPT Plus/Pro subscription sign-in (OAuth) |
| Glossary | User term list | Feeds recognition hints and the LLM prompt |
| Reliability | Auto-recovery | Recognizer rebuild after consecutive errors, error backoff, combo-key cancellation |

Menu controls:

- `Language` changes the recognition locale.
- `LLM Refinement` toggles cleanup and opens settings (provider, model, ChatGPT sign-in, glossary).
- `Auto-stop on Silence` ends recording after a quiet pause.
- `Start Locked Recording` / `Stop Locked Recording & Save` toggles the long-form session.
- `Transcript Window…` opens the live long-form transcript.
- `Subtitle Overlay` toggles the caption overlay for long-form sessions.
- `Trigger Key…` configures the dictation and long-form keys.
- `Permissions...` shows microphone, speech, input monitoring, and accessibility status.

## Long-form (locked) recording

Press ⌃⇧Fn (or trigger+Shift, or the dedicated long-form key) to start a
hands-free session; press it again to stop and save. While recording, the
menu bar icon switches to ⏺, a start/stop sound plays, and a caption badge
flashes so you always know the toggle registered.

- Runs on the macOS 26 **SpeechAnalyzer** long-form engine, so long silences
  (a quiet pre-meeting stretch, a pause between speakers) never kill the session.
- The transcript is saved to `~/Documents/MacWhisper/transcript-<timestamp>.txt`
  — never the clipboard.
- The raw audio is always backed up to `recording-<timestamp>.m4a`, so even a
  total transcription failure cannot lose the capture.
- The partial transcript is autosaved every 2 seconds for crash recovery.
- Silence-only sessions are discarded entirely — no stray files.
- A live `Transcript Window` (from the menu) and a caption-style subtitle
  overlay at the bottom of the screen show the text as it arrives. The overlay
  shows the last two sentences, reveals a close button on hover, and can be
  toggled from the menu; closing it never touches the recording.
- With LLM refinement on, the raw transcript is saved first, then refined in
  chunks in the background — a refinement failure keeps the raw text.

## Install

Download the latest `MacWhisper.dmg` from
[Releases](https://github.com/spooncast/mac-whisper/releases/latest), open it,
and drag **Mac Whisper** into Applications.

Or build the app locally:

```bash
git clone https://github.com/spooncast/mac-whisper.git
cd mac-whisper
make app
open "build/Mac Whisper.app"
```

Requirements:

- macOS 26+
- Xcode command-line tools
- Microphone permission
- Speech Recognition permission
- Input Monitoring permission
- Accessibility permission

For stable local permissions across rebuilds, create a self-signed signing
identity once:

```bash
make cert
make app
```

Without that identity, ad hoc signing can make macOS ask for Input Monitoring
and Accessibility permissions again after each rebuild.

## How It Works

The app creates a fresh speech session when the trigger goes down.

```text
⌃Fn down -> start audio engine -> stream recognition -> update HUD
⌃Fn up   -> stop recognition -> optionally refine -> paste text
```

### LLM refinement

Two ways to authenticate:

- **ChatGPT Plus/Pro subscription** — click `Sign in with ChatGPT` in LLM
  Settings (OAuth in the browser, no API key). Models: `gpt-5.4-mini`
  (default), `gpt-5.5`, `gpt-5.4`.
- **API key providers** (OpenAI-compatible and Anthropic-compatible endpoints)
  — the key comes from the environment:

```bash
cp .env.example .env
# edit .env:
#   MACWHISPER_LLM_API_KEY=sk-...
make run
```

Installed apps launched from Finder can use:

```bash
launchctl setenv MACWHISPER_LLM_API_KEY sk-...
```

You can also put the same line in `~/.config/macwhisper/.env`.

### Glossary

Attach or edit a plain text file in LLM Settings → Glossary. One term per
line; `wrong -> right` lines map a common mis-transcription to the preferred
spelling; `#` lines are comments. The terms feed both the speech recognizer's
contextual hints and the LLM refinement prompt.

## Build

Compile:

```bash
make build
```

Build and launch:

```bash
make run
```

Create a DMG:

```bash
make dmg
```

## For agents

One-time setup to build and launch the app:

```bash
cd /path/to/mac-whisper
make app
open "build/Mac Whisper.app"
```

For a quick compile check, run:

```bash
swift build
```

## Security

- The app needs microphone and speech recognition access to transcribe audio.
- Input Monitoring is used only to read the trigger keys (Fn/Globe and the configured keys).
- Accessibility is used to paste text into the focused app.
- Transcript text is not written to the diagnostic log.
- The LLM API key is read from the environment, not from UserDefaults.
- ChatGPT OAuth tokens are stored in `~/.config/macwhisper/chatgpt-oauth.json` with owner-only permissions.
- Long-form transcripts and audio backups stay local, in `~/Documents/MacWhisper`.
- If LLM cleanup fails, the app pastes (or keeps) the raw transcript.

## Tests

```bash
swift build
```

Manual checks still matter because macOS permissions, HID input, paste
injection, and audio routing depend on system state.

## Release

Current tag: [`0.0.3`](https://github.com/spooncast/mac-whisper/releases/tag/0.0.3)

The `0.0.3` release moves the push-to-talk trigger to ⌃Fn with configurable
trigger keys, adds the locked long-form recording mode (SpeechAnalyzer, file
output, audio backup, subtitle overlay, transcript window), ChatGPT Plus/Pro
subscription sign-in for LLM refinement, a user glossary, and reliability
fixes for the recognizer and clipboard paste.

## License

MIT
