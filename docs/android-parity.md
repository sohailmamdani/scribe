# Scribe Android parity plan

This document is the completion contract for the Android port. A green Android
build is a milestone, not proof of parity. Each row is complete only after the
implementation and the listed runtime evidence exist.

## Platform architecture

- **Containing app:** a native Kotlin/Jetpack Compose activity owns onboarding,
  microphone permission, on-device recognizer availability/model download,
  recent dictations, privacy explanations, and keyboard preferences.
- **Keyboard:** an `InputMethodService` renders the Scribe key surface and edits
  the focused field through `InputConnection`.
- **Dictation:** unlike an iOS keyboard extension, a visible Android IME can use
  the app UID's granted microphone permission. The keyboard therefore creates
  Android's on-device `SpeechRecognizer` directly. It never selects the generic
  recognizer because that implementation may send audio to a server.
- **Shared state:** app and IME are components of one Android package, so private
  `SharedPreferences` and app-private history replace the iOS App Group request
  protocol. No transcript or audio is placed in external storage.
- **Compatibility floor:** Android 12 / API 31, the first release with the
  explicit on-device recognizer factory. Devices without an installed on-device
  recognition service get model/setup guidance, never a silent cloud fallback.

## Parity matrix

| iOS behavior | Android analogue | Proof required |
| --- | --- | --- |
| Containing-app model and permission onboarding | Compose setup/status screen, runtime `RECORD_AUDIO`, enabled/default IME checks | UI test plus real-device setup |
| Large-v3 WhisperKit, offline only | `createOnDeviceSpeechRecognizer`; support check and model download | airplane-mode dictation on supported hardware |
| Tap-to-dictate in containing app | app-owned on-device speech session | device dictation and local-history check |
| Keyboard dictation handoff | direct IME on-device speech session | dictate into at least two third-party apps |
| Start, stop, cancel, partial level/status, error/retry | IME dictation toolbar and recognizer callbacks | device interaction and error-path tests |
| Finished-text cleanup and contextual spacing | Kotlin port of deterministic transcript polish/insertion rules | unit tests and field insertion check |
| Apple Intelligence punctuation refinement | API 33+ quality-optimized on-device recognizer formatting, guarded against changed/reordered raw words | intent and faithfulness-policy tests plus device dictation |
| Local recent-dictation history/copy | app-private history shared by app and IME | restart persistence and clipboard check |
| QWERTY letters, shift/caps, delete, space, return | custom responsive IME key surface and `InputConnection` edits | portrait/landscape phone and tablet QA |
| `123`, `#+=`, Gboard-like punctuation layout | Android symbol pages with configurable return scope | unit tests plus visual QA |
| Long-press/down-flick alternates and key previews | touch-state alternate selection and preview bubble | gesture tests plus device QA |
| Hold-delete and delete-word behavior | repeating deletion and word-delete gesture/action | unit and device checks |
| Double-space period and automatic capitalization | context-aware Android editing rules | unit tests across sentence/word fields |
| Conservative autocorrect, candidates, undo | bundled lexicon, edit-distance ranking, composing/candidate surface | corpus tests and device QA |
| Word swipe | resampled QWERTY shape decoder with endpoint and frequency weighting over the shared word list | decoder tests and device QA |
| Space-bar cursor mode | horizontal drag mapped to selection movement | editable-field device QA |
| Host field traits | `EditorInfo.inputType`/`imeOptions` layouts and action labels | number, phone, email, URL, password, search tests |
| Globe/input-mode switch | system next-input-method action | multi-keyboard device QA |
| Haptics, previews, symbol behavior settings | private shared preferences consumed on IME activation | app/IME round-trip tests |
| VoiceOver/accessibility actions | virtual accessibility nodes and spoken key/alternate names | TalkBack audit |
| Privacy: no analytics/upload/audio retention | no network permission; only explicit on-device recognizer | manifest audit and offline runtime proof |
| iPhone/iPad adaptive layout | Android phone/tablet/foldable/landscape sizing | screenshot matrix and layout tests |
| TestFlight distribution | signed AAB/APK with unique `versionCode`; internal Play track or approved direct-install release path | signed artifact and tester availability |

## Current verified implementation

As of Android `versionCode` 15, the repository has local automated evidence for:

- field profiles derived from `EditorInfo`, including numeric, decimal, signed,
  phone, date, time, email, URL, password, multiline, and search/action
  behavior, with date/time separators, search-field double-space parity, and
  dedicated pads that cannot accidentally switch back to letters;
- password-field suppression of dictation, transcript state, suggestions, and
  the microphone control;
- TalkBack virtual button nodes for every rendered key, spoken punctuation and
  alternate names, click actions, and long-click alternate actions;
- guarded undo of the last dictation, plus hold-delete acceleration from
  characters to whole words using Unicode code-point deletion;
- the exact 236,859-row iOS bigram corpus, context/frequency/tap-distance
  correction ranking, unambiguous contractions, and private accept/reject
  learning (the packaged corpus matches the source SHA-256);
- an iOS-matched synchronous contraction fallback, so a fast `dont` plus Space
  or punctuation cannot outrun the asynchronous candidate lookup, while
  rejected and Personal Dictionary words remain protected;
- the iOS-style resampled QWERTY swipe-path scorer, including neighboring
  start/end keys, shape-distance rejection, and corpus-frequency weighting;
- gap-free touch regions that meet halfway across visual cap spacing, extend
  outer keys to the keyboard edges, compensate for vertical finger aim, and
  stop resolving after the finger leaves the keyboard;
- a visible, TalkBack-labelled one-tap autocorrection undo for both automatic
  and manually selected candidates, plus character-evidence preservation while
  deleting within a word;
- a conditional next-input-method key and an in-place landscape IME instead of
  Android's fullscreen extracted editor;
- iOS-matched long-press alternates on both letters and the `123` digit row,
  including TalkBack names and removal of the long-click action when alternates
  are disabled;
- host selection synchronization that clears stale tap/correction state and
  deletes selected text as a selection rather than deleting before the caret;
- iOS-matched protection for acronyms and unexpected internal capitals, plus
  Android's no-personalized-learning editor flag suppressing correction
  feedback and IME dictation-history persistence;
- locale-scoped Android Personal Dictionary words and shortcuts, loaded
  read-only by the active IME, protected from replacement, and ranked alongside
  bundled correction candidates without persisting a second copy;
- state-specific accessibility labels for the containing app's dictation and
  setup actions, alongside the keyboard's virtual-key accessibility surface;
- explicit fresh-session Retry actions after recognition failure in both the
  containing app and IME, with preparation/processing controls exposed to
  TalkBack as status-only instead of clickable no-ops;
- document-generation binding for IME dictation, including cancellation while
  recognition is processing and rejection of late partial, level, or final
  callbacks after the keyboard moves to another app, field, or password input,
  with the prior document's transient transcript/status cleared on transition;
- a shared document-work generation gate for asynchronous swipe decoding and
  correction candidates, invalidated at the earliest input lifecycle boundary
  so work started in one app cannot insert into or update the next app;
- swipe insertion without a forced trailing space, with punctuation-aware word
  boundaries and manual Shift carried into the decoded word;
- deliberate 350 ms space-bar cursor activation, plus a punctuation palette
  that honors alternate-symbol enablement, the configured hold delay, and the
  selected return-to-letters scope;
- the API 34 model-download progress/success/scheduled/error contract, with an
  API 33 fallback, explicit installed/pending/downloadable model states, and
  generation-gated callbacks so stale support/download work cannot end a new
  dictation session;
- API 33+ quality-optimized on-device punctuation/capitalization, with the
  documented formatted/raw pair checked by the same word-subsequence
  faithfulness rule as iOS and a singleton fallback for recognizers that ignore
  the formatting request;
- all 68 Android unit tests, all 20 instrumentation tests on an API 36 emulator,
  APK assembly, lint, and a manifest with no `INTERNET` permission;
- live IME correction of `teh` to `the ` and explicit restoration to `teh `,
  typing into Chrome's address field, and an in-place landscape session with
  Android reporting `mFullscreenMode=false`;
- live Chrome verification of selected-text deletion, the `1` → `!` long-press
  alternate, consecutive `the the` swipes without trailing spaces, and a
  manually shifted `The` swipe;
- live Chrome verification that a deliberate space-bar drag changes the host
  selection and inserts the next character before the untouched trailing text.

The emulator's package-manager low-storage threshold was reduced only for APK
installation and instrumentation, then restored; no unrelated app data was
deleted. The remaining release evidence is a physical-device TalkBack audit,
airplane-mode dictation with audible speech, the complete two-third-party-app
field matrix, tablet/foldable visual QA, a production-signed Android artifact,
and Android tester distribution. Those rows remain open rather than inferred
from emulator or unit-test results.

## Known platform substitutions

- Android API 33+ exposes native speech formatting rather than a general system
  language-model session. Scribe requests its quality mode only from the
  explicit on-device recognizer and accepts the formatted hypothesis only when
  it preserves the raw word sequence. API 31–32 and recognizers that ignore the
  request retain the deterministic transcript polisher.
- Android does not require the 15-minute iOS background microphone keep-alive.
  Direct capture while the IME is visible is both simpler and more private.
- Android does not expose the user's full Gboard lexicon to another IME. Scribe
  reads the platform Personal Dictionary while active, uses its bundled
  frequency dictionaries for the wider vocabulary, and records accepted or
  rejected corrections privately.

## Release completion

Android work is not parity-complete until all rows above have authoritative
evidence, the iOS targets still build and test, the Android app and IME pass unit
and instrumentation tests, a signed Android artifact has a unique version code,
and the artifact is available to the intended internal testers.
