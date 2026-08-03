#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PROJECT="Scribe.xcodeproj"
SCHEME="Scribe iOS"
CONFIGURATION="Release"
APP_GROUP="group.sohail.Scribe"
EXPORT_OPTIONS="Config/TestFlightExportOptions.plist"

BUILD_SETTINGS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -showBuildSettings)
VERSION=$(awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }' <<<"$BUILD_SETTINGS")
BUILD=$(awk -F ' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION = / { print $2; exit }' <<<"$BUILD_SETTINGS")

[[ -n "$VERSION" && -n "$BUILD" ]] || {
    echo "Could not read the iOS version and build number from Xcode."
    exit 1
}

ARCHIVE_PATH=${ARCHIVE_PATH:-"/private/tmp/Scribe-$VERSION-$BUILD-signed.xcarchive"}
EXPORT_PATH=${EXPORT_PATH:-"/private/tmp/Scribe-$VERSION-$BUILD-upload"}
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-"/private/tmp/scribe-ios-$BUILD-derived"}

for path in "$ARCHIVE_PATH" "$EXPORT_PATH" "$DERIVED_DATA_PATH"; do
    [[ ! -e "$path" ]] || {
        echo "Release path already exists: $path"
        echo "Choose a fresh build number or set explicit ARCHIVE_PATH, EXPORT_PATH, and DERIVED_DATA_PATH values."
        exit 1
    }
done

echo "Archiving Scribe $VERSION ($BUILD) with verified App Store profiles..."
xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    archive

APP="$ARCHIVE_PATH/Products/Applications/Scribe.app"
KEYBOARD="$APP/PlugIns/ScribeKeyboard.appex"

[[ -d "$APP" && -d "$KEYBOARD" ]] || {
    echo "The archive does not contain the Scribe app and embedded keyboard."
    exit 1
}

verify_version() {
    local bundle=$1
    local label=$2
    local plist="$bundle/Info.plist"
    local actual_version actual_build

    actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
    actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
    [[ "$actual_version" == "$VERSION" && "$actual_build" == "$BUILD" ]] || {
        echo "$label has version $actual_version ($actual_build), expected $VERSION ($BUILD)."
        exit 1
    }
}

verify_app_group() {
    local bundle=$1
    local label=$2
    local entitlements actual_group

    entitlements=$(mktemp -t scribe-entitlements.XXXXXX.plist)
    codesign -d --entitlements :- "$bundle" >"$entitlements" 2>/dev/null
    actual_group=$(/usr/libexec/PlistBuddy \
        -c 'Print :com.apple.security.application-groups:0' \
        "$entitlements" 2>/dev/null || true)
    rm -f "$entitlements"

    [[ "$actual_group" == "$APP_GROUP" ]] || {
        echo "$label is missing the signed App Group entitlement $APP_GROUP."
        exit 1
    }
}

verify_version "$APP" "Containing app"
verify_version "$KEYBOARD" "Keyboard extension"
codesign --verify --deep --strict "$APP"
verify_app_group "$APP" "Containing app"
verify_app_group "$KEYBOARD" "Keyboard extension"
echo "Verified signed App Group entitlement on the app and keyboard."

echo "Uploading Scribe $VERSION ($BUILD) to App Store Connect..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

echo "Uploaded Scribe $VERSION ($BUILD)."
