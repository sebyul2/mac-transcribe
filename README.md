# Mac Whisper

A macOS menu-bar app for voice: hold a key to dictate into any app, record long sessions like meetings to files, and get live translated captions while someone speaks — all running locally except the optional LLM polish.

Requires **macOS 26** (Tahoe) or later.

[**Download MacWhisper.dmg**](https://github.com/sebyul2/mac-transcribe/raw/main/build/MacWhisper.dmg)

## What it does

**Push-to-talk dictation.** Hold the trigger key (⌃Fn on the built-in keyboard, Left Ctrl by default on external keyboards — both configurable), speak, release. Your words are recognized on-device, optionally cleaned up by an LLM, and pasted into whatever app you were using.

**Long-form recording.** Press the trigger + Shift to start a hands-free session for meetings and lectures. It uses macOS 26's long-form speech engine (SpeechAnalyzer), so hours-long sessions with long silences are fine. Everything is protected against loss: the raw audio is backed up to an `.m4a` as it records, and the partial transcript is autosaved every 2 seconds — a crash or force-quit costs you at most the last 2 seconds. Results land in `~/Documents/MacWhisper/`.

**Live interpretation.** Turn on Live Translation and a long-form session becomes a one-way simultaneous interpreter: movie-style captions at the bottom of the screen show the translation as speech happens. Translation is two-tier — Apple's on-device translator drafts each line in ~100 ms (rendered dimmed), then the LLM's context-aware result replaces it in white. Utterances are split by real speech pauses detected in the recognizer's word timing, so different speakers don't run together, and translation context never crosses a speaker change.

**Auto meeting notes.** Optionally have the LLM turn a finished recording into structured minutes (attendees, discussion, decisions, action items — with Mermaid diagrams where they help), saved as Markdown next to the transcript.

**Glossary.** Attach a plain-text glossary (one term per line, `wrong -> right` mappings supported). Terms feed both the speech recognizer's vocabulary hints and the LLM prompts, so your product names and jargon come out right.

**System audio input.** Sessions can listen to what the Mac itself is playing (calls, videos) instead of the microphone, via ScreenCaptureKit.

## Keys

| Action | Built-in keyboard | External keyboard (default) |
|---|---|---|
| Dictate (hold) | ⌃Fn | Left Ctrl |
| Long-form / interpreter (toggle) | ⌃⇧Fn | Left Ctrl + Left Shift |

Both triggers are freely remappable — including full combos like ⌘⇧R — from **menu → Trigger Keys…**.

## LLM setup (optional)

Everything works without an LLM; with one, dictation gets cleaned up, captions get quality translation, and meeting notes become available. Choose in **menu → LLM Refinement → Settings…**:

- **ChatGPT subscription** — sign in with your ChatGPT Plus/Pro account (OAuth, no API key)
- **OpenAI-compatible API** — any endpoint + key
- **Anthropic API** — key-based

## Permissions

The app asks for what each feature needs: **Microphone** and **Speech Recognition** for dictation, **Input Monitoring** for the trigger keys, **Accessibility** for pasting, and **Screen Recording** only if you use system-audio input. Check them anytime in **menu → Permissions…**.

## Install / build

Download the DMG above, or build from source:

```sh
make app      # builds build/Mac Whisper.app
make dmg      # packages build/MacWhisper.dmg
```

Copy `build/Mac Whisper.app` to `/Applications`.

## Files

| Path | What |
|---|---|
| `~/Documents/MacWhisper/transcript-*.txt` | session transcripts (one line per utterance) |
| `~/Documents/MacWhisper/recording-*.m4a` | raw audio backups |
| `~/Documents/MacWhisper/notes-*.md` | generated meeting minutes |

## Credits

Originally created by [Tony Lee](https://github.com/bytonylee/mac-whisper). This fork has since been substantially rewritten and extended.

MIT licensed — see [LICENSE](./LICENSE).
