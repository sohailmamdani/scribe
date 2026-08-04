# Scribe for iOS architecture

Scribe for iOS is split across three source roots:

- `ScribeMobile`: the containing SwiftUI app. It owns microphone permission, `AVAudioSession`, audio recording, WhisperKit model loading, transcription, and background completion.
- `ScribeKeyboard`: the `UIInputViewController` keyboard extension. It provides letters, numbers, symbols, dictation controls, state feedback, and cursor insertion through `UITextDocumentProxy`.
- `ScribeShared`: the small Foundation-only contract compiled into both processes.

## Dictation flow

1. The keyboard writes a pending command into the shared App Group and asks iOS to wake the containing app through `scribe://wake`.
2. When Scribe becomes active, the containing app consumes the pending command, loads a pinned WhisperKit model if needed, requests microphone access, and begins recording. Upgrades keep cached Base immediately usable while the compressed Large-v3 High Accuracy model installs in parallel.
3. The user returns to the originating app. On iOS versions that do not switch back automatically, Scribe shows a clear swipe-back instruction. The keyboard polls the App Group and reflects recording state and audio level.
4. Tapping stop writes a stop command. The containing app stops recording and finishes transcription under a background task.
5. The app retries Core ML inference with the Base model in CPU-only compatibility mode if Large-v3 fails with a recognized Core ML or prediction error. The compatibility preference is versioned by model and OS version, and failed recordings remain on disk for a user-initiated retry instead of being deleted.
6. The app removes conservative filler words and direct word repeats, then publishes the result with a unique result identifier.
7. The keyboard consumes the result exactly once, adjusts spacing for the surrounding text, and calls `textDocumentProxy.insertText`.

No audio is placed in the App Group. Only commands, status, an audio meter value, and the finished text cross the process boundary.

## App Group and identifiers

- App: `sohail.Scribe.mobile`
- Keyboard: `sohail.Scribe.mobile.keyboard`
- App Group: `group.sohail.Scribe`
- URL scheme: `scribe://wake`; the pending App Group command determines whether to start, stop, cancel, or retry.

Both targets need the App Group enabled in the Apple Developer portal before installing a signed device build.

## Current product boundary

The keyboard uses the same portrait key height, column width, control proportions, and spacing measured from the iOS 26 system keyboard on iPhone 17 Pro Max, with one additional native row pitch for permanent numbers. Its requested extension height includes a dedicated gap between the dictation bar and number row so neither surface is compressed or allowed to touch. Common alternates are printed on the key caps and can be entered by a downward flick, press-and-hold selection, or a named VoiceOver action. Double-space period, automatic capitalization, host-trait-aware autocorrection, hold-delete, word swiping, and space-bar cursor mode remain available.

## TestFlight release

Run `scripts/release-ios-testflight.sh` after incrementing `CURRENT_PROJECT_VERSION` for both iOS targets. The Release configurations use the explicit `Scribe iOS App Store` and `Scribe Keyboard App Store` profiles. The script creates a signed archive, verifies `group.sohail.Scribe` on the archived app and keyboard signatures, and only then uploads through App Store Connect.

Do not archive with `CODE_SIGNING_ALLOWED=NO` for TestFlight. An unsigned archive does not retain the custom App Group entitlement for the later export-signing step, even when the entitlement files and Apple Developer App IDs are configured correctly.
