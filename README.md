# Scribe

A native macOS, iOS, and Android speech-to-text app that runs entirely on your device.

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
- **No audio uploads.** Transcription stays on-device. Network access is limited to downloading the Whisper models and checking for desktop app updates; existing installs may continue dictating with Base while Large-v3 downloads.
- **No account, no sign-up.** The app does not have a server.
- **No retained background audio.** During an active 15-minute iOS keyboard session, Scribe keeps the microphone route alive so the next dictation starts reliably, but discards interim audio buffers immediately. Only an explicit dictation is saved or transcribed.
- **Network use is limited and explicit.** Scribe downloads its on-device Whisper model from Hugging Face. The macOS app also checks a small GitHub Pages `appcast.xml` once a day for updates; Sparkle's optional system profiling is disabled, and automatic checks can be turned off.

If privacy is the reason you're here, Scribe is the right shape for you.

## Requirements

- macOS 14 or later (Apple Silicon recommended).
- Microphone access (the app will prompt on first run).
- Accessibility permission, only if you want auto-paste into other apps.

For the iOS app and keyboard:

- iOS or iPadOS 18 or later.
- Microphone access in the containing Scribe app.
- Scribe Keyboard enabled with Full Access. Full Access is used for private App Group communication between the keyboard and Scribe; transcription remains on-device.

For the Android app and keyboard:

- Android 12 or later.
- An installed Android on-device speech recognition service and language model.
- Microphone access granted to Scribe and the Scribe input method enabled.

## iPhone and iPad

The `Scribe iOS` target includes a containing app and an embedded `ScribeKeyboard` extension. From any standard text field, switch to Scribe Keyboard and tap **Dictate**. The keyboard asks iOS to open Scribe, the containing app activates the microphone, and recording continues while you return to the original app. Scribe transcribes and polishes the recording locally and inserts the result at the cursor. On recent iOS versions, you may need to swipe back once after Scribe opens.

The iOS app uses Argmax's compressed Whisper Large-v3 model for High Accuracy transcription. Existing installs can keep dictating with their cached Base model while Large-v3 downloads and prepares; interrupted transfers resume from their partial cache, and Base remains the CPU-only fallback when Core ML rejects a prediction. The keyboard follows the captured iOS four-row key grid, keeps numbers behind `123` and downward-flick alternates, offers ranked correction candidates with one-tap undo, and supports press-and-hold alternates.

To enable the keyboard:

1. Install and open Scribe once so its on-device model can be prepared.
2. Open Settings → General → Keyboard → Keyboards → Add New Keyboard.
3. Choose Scribe, then enable **Allow Full Access**.

The handoff through the containing app is required because iOS does not give custom keyboard extensions direct microphone access. See [the iOS architecture](docs/ios-architecture.md) for implementation details.

## Android

The `androidApp` module contains a native Jetpack Compose setup/dictation app
and a custom `InputMethodService`. Android allows the visible IME to use the
app's granted microphone permission, so keyboard dictation runs through the
explicit on-device `SpeechRecognizer` without opening the containing app or
keeping a background microphone session alive. Scribe never selects Android's
generic recognizer and does not declare the internet permission.

Open Scribe once to grant microphone access, enable the Scribe keyboard, and
select it as the current input method. The containing app includes a test field
for checking typing and dictation before switching to another app. Android port
status and the requirement-by-requirement parity evidence are tracked in
[the Android parity plan](docs/android-parity.md).

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

Choose the `Scribe iOS` scheme to build the iPhone/iPad app and its keyboard extension, or `Scribe` for the original macOS app.

Android builds require Android Studio's JDK and Android SDK 36:

```bash
./gradlew :androidApp:testDebugUnitTest :androidApp:assembleDebug
```

The debug APK is written to
`androidApp/build/outputs/apk/debug/androidApp-debug.apk`.

## Releasing (maintainer only)

Releases are published via `scripts/release.sh <version>` which builds the app, creates a signed DMG, updates the Sparkle appcast, tags, and publishes a GitHub release. Requires the Sparkle private key in your macOS Keychain (one-time `tools/bin/generate_keys`).

## License

[MIT](LICENSE) © 2026 Sohail Mamdani
