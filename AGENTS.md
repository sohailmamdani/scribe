# Scribe Repository Instructions

## Completion Bar

Apply the completion bar for the platform actually changed. Do not create an
unrelated Apple or Android release merely because another platform, documentation,
or repository configuration changed.

### Every repository change

1. Verify the change with the relevant tests, builds, or static checks.
2. Commit all intended repository changes.
3. Push the commit to `origin/main`.

### iOS-affecting changes

Apply these additional steps only when a change affects iOS app or keyboard
behavior, iOS resources, iOS dependencies, signing, packaging, or shared code
used by an iOS target:

1. Increment `CURRENT_PROJECT_VERSION` for both the `Scribe iOS` app and
   `ScribeKeyboard` extension so App Store Connect receives a unique build.
2. Run `scripts/release-ios-testflight.sh` to archive, validate the signed App
   Group entitlements, and upload one fresh build to TestFlight.
3. Verify that App Store Connect finishes processing the build and that it is
   assigned to the Internal Testers group.

Android-only changes, documentation-only changes, and repository-instruction
changes must not increment the iOS build number or trigger a TestFlight upload.

### Android-affecting changes

Run the relevant Android unit, instrumentation, lint, and assembly checks for
the scope changed. Increment Android `versionCode` and create a signed release
artifact only when producing a new Android tester or production release. An
Android-only change must not trigger an iOS build-number increment or TestFlight
upload.

### Documentation and configuration

Use targeted validation for documentation, instructions, and configuration.
Do not release either mobile platform unless the change affects that platform's
runtime behavior, dependencies, signing, packaging, or release artifact.

### Release batching and blockers

Batch a coherent set of accepted changes into one platform release rather than
uploading a new build for every interim commit. A user request for an immediate
release overrides batching. If a required platform-specific step is blocked,
report that blocker explicitly instead of describing that platform release as
complete.
