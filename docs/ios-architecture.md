# Scribe for iOS architecture

Scribe for iOS is split across three source roots:

- `ScribeMobile`: the containing SwiftUI app. It owns microphone permission, `AVAudioSession`, audio recording, WhisperKit model loading, transcription, and background completion.
- `ScribeKeyboard`: the `UIInputViewController` keyboard extension. It provides letters, numbers, symbols, dictation controls, state feedback, and cursor insertion through `UITextDocumentProxy`.
- `ScribeShared`: the small Foundation-only contract compiled into both processes.

## Dictation flow

1. The keyboard writes a pending start command into the shared App Group and asks iOS to open `scribe://dictate` through its extension context.
2. When Scribe becomes active, the containing app consumes the pending command, loads a pinned WhisperKit model if needed, requests microphone access, and begins recording.
3. The user returns to the originating app. On iOS versions that do not switch back automatically, Scribe shows a clear swipe-back instruction. The keyboard polls the App Group and reflects recording state and audio level.
4. Tapping stop writes a stop command. The containing app stops recording and finishes transcription under a background task.
5. The app retries Core ML inference with CPU-only compatibility mode if the normal CPU/GPU path fails. Failed recordings remain on disk for a user-initiated retry instead of being deleted.
6. The app removes conservative filler words and direct word repeats, then publishes the result with a unique result identifier.
7. The keyboard consumes the result exactly once, adjusts spacing for the surrounding text, and calls `textDocumentProxy.insertText`.

No audio is placed in the App Group. Only commands, status, an audio meter value, and the finished text cross the process boundary.

## App Group and identifiers

- App: `sohail.Scribe.mobile`
- Keyboard: `sohail.Scribe.mobile.keyboard`
- App Group: `group.sohail.Scribe`
- URL schemes: `scribe://dictate` and `scribe://retry`

Both targets need the App Group enabled in the Apple Developer portal before installing a signed device build.

## Current product boundary

This first build provides the system keyboard, app handoff, local transcription, conservative text cleanup, context-aware insertion, safe undo, recent local history, and recording/transcription state. More aggressive AI rewriting, custom vocabulary, live partial text, Action Button/App Intent entry points, and a selectable Parakeet engine remain separate follow-on features so the first release can be validated against real dictation before changing users' words more aggressively.

## TestFlight release

Run `scripts/release-ios-testflight.sh` after incrementing `CURRENT_PROJECT_VERSION` for both iOS targets. The Release configurations use the explicit `Scribe iOS App Store` and `Scribe Keyboard App Store` profiles. The script creates a signed archive, verifies `group.sohail.Scribe` on the archived app and keyboard signatures, and only then uploads through App Store Connect.

Do not archive with `CODE_SIGNING_ALLOWED=NO` for TestFlight. An unsigned archive does not retain the custom App Group entitlement for the later export-signing step, even when the entitlement files and Apple Developer App IDs are configured correctly.
