#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
SIMULATOR=${1:-booted}
WORK=$(mktemp -d /tmp/scribe-keyboard-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun --sdk iphonesimulator swiftc -O -parse-as-library \
    -target "$ARCH-apple-ios18.0-simulator" -sdk "$SDK" \
    ScribeShared/KeyboardEditingRules.swift \
    ScribeShared/KeyboardCorrectionRanking.swift \
    ScribeShared/KeyboardInputQueue.swift \
    ScribeKeyboard/KeyboardAutocorrectionEngine.swift \
    ScribeKeyboard/KeyboardWordBoundaryEditor.swift \
    ScribeKeyboard/KeyboardTouchSurface.swift \
    ScribeKeyboard/SwipeWordDecoder.swift \
    Tests/iOSKeyboardHarness/Probe.swift \
    -o "$WORK/keyboard-tests"
xcrun simctl spawn "$SIMULATOR" "$WORK/keyboard-tests" "$ROOT/ScribeKeyboard"
