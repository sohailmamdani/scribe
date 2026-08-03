# Scribe Repository Instructions

## Completion Bar

A change in this repository is not complete until every item below is finished:

1. Verify the change with the relevant tests and builds.
2. Increment `CURRENT_PROJECT_VERSION` for both the `Scribe iOS` app and `ScribeKeyboard` extension so App Store Connect receives a unique build.
3. Commit all intended repository changes.
4. Push the commit to `origin/main`.
5. Run `scripts/release-ios-testflight.sh` to archive, validate the signed App Group entitlements, and upload a fresh build to TestFlight.
6. Verify that App Store Connect finishes processing the build and that it is assigned to the Internal Testers group.

Always apply this completion bar after every change, including documentation and configuration changes. Do not stop after a local implementation, build, archive, or upload acknowledgment. If any step is blocked, report the blocker explicitly instead of describing the work as complete.
