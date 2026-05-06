# Scribe

A native macOS speech-to-text app that runs entirely on your machine.

Press a global hotkey, speak, release — your words are transcribed locally and pasted into whatever app is in front of you. No cloud, no account, no upload.

## What it does

- **Global hotkey to dictate.** Default ⌘⌥⌃V (rebindable in Settings). Works system-wide; the active window receives the transcribed text via auto-paste.
- **On-device transcription** via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift). The Whisper model runs on Apple Silicon — no audio ever leaves your Mac.
- **Transcription history** kept locally in the app window so you can re-copy any past dictation.
- **Floating window mode** for keeping Scribe on top while you work in another app.
- **Light / Dark / System theme** and customizable shortcut, all in Settings (⌘,).

## Privacy

Scribe is built around a simple promise: your voice stays on your device.

- **No analytics.** No telemetry, no crash reporting, no usage tracking. Nothing is sent anywhere.
- **No network calls during transcription.** WhisperKit downloads the model from Hugging Face on first launch (~3 GB); after that, transcription is fully offline.
- **No account, no sign-up.** The app does not have a server.
- **No background recording.** The microphone is only active while you're holding (or have toggled on) recording.
- **Auto-update is the only outbound network call.** Once a day, the app fetches a small XML file (`appcast.xml`) from GitHub Pages to check for new versions. No identifying information is sent — Sparkle's optional system-profiling feature is explicitly disabled. You can turn off automatic checks entirely in the update prompt.

If privacy is the reason you're here, Scribe is the right shape for you.

## Requirements

- macOS 14 or later (Apple Silicon recommended).
- Microphone access (the app will prompt on first run).
- Accessibility permission, only if you want auto-paste into other apps.

## Install

Download `Scribe-1.5.dmg` from the [Releases](https://github.com/sohailmamdani/scribe/releases) page, open it, drag `Scribe.app` to `/Applications`. The first launch downloads the Whisper model — give it a couple of minutes.

## Build from source

Requires Xcode 16 or later.

```bash
git clone https://github.com/sohailmamdani/scribe.git
cd scribe
open Scribe.xcodeproj
```

Then ⌘R in Xcode. Swift Package Manager will resolve `argmax-oss-swift` and `Sparkle` on first open.

## Releasing (maintainer only)

Releases are published via `scripts/release.sh <version>` which builds the app, creates a signed DMG, updates the Sparkle appcast, tags, and publishes a GitHub release. Requires the Sparkle private key in your macOS Keychain (one-time `tools/bin/generate_keys`).

## License

[MIT](LICENSE) © 2026 Sohail Mamdani
