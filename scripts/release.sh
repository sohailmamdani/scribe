#!/bin/bash
# Cuts a new release: builds with Developer ID, notarizes, staples,
# signs the DMG, updates the Sparkle appcast, tags, and publishes a
# GitHub release with the DMG attached.
#
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 1.6
#
# Pre-requisites:
#   - MARKETING_VERSION + CURRENT_PROJECT_VERSION bumped in project.pbxproj
#   - Sparkle CLI tools: ./scripts/install-tools.sh
#   - Sparkle private key in Keychain (one-time `tools/bin/generate_keys`)
#   - Developer ID Application cert in Keychain
#   - notarytool keychain profile "scribe-notary" (one-time
#     `xcrun notarytool store-credentials scribe-notary ...`)
#   - gh CLI authenticated

set -euo pipefail

VERSION="${1:?Usage: $0 <version>  (e.g. 1.6)}"
TAG="v$VERSION"
DMG="Scribe-$VERSION.dmg"
APP_PATH="build/release/Build/Products/Release/Scribe.app"
APPCAST="docs/appcast.xml"
RELEASE_NOTES_URL="https://github.com/sohailmamdani/scribe/releases/tag/$TAG"

CODESIGN_IDENTITY="Developer ID Application: Sohail Mamdani (N3WXD74E2V)"
NOTARY_PROFILE="scribe-notary"

# ----- Pre-flight checks (fail loud, fail early) -----
[[ -x "tools/bin/sign_update" ]] || { echo "✗ Sparkle tools missing — run scripts/install-tools.sh"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ Working tree dirty — commit or stash first"; exit 1; }

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application: Sohail Mamdani"; then
    echo "✗ Developer ID Application cert not found in keychain"; exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat <<EOF
✗ notarytool keychain profile "$NOTARY_PROFILE" not set up.

One-time setup:
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
        --apple-id <your-apple-id-email> \\
        --team-id N3WXD74E2V \\
        --password <app-specific-password>

Generate the app-specific password at https://account.apple.com → Sign-In and Security.
EOF
    exit 1
fi

# ----- Build with Developer ID -----
echo "▶ Building Scribe.app (Release, Developer ID)..."
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath build/release \
    CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    clean build > /tmp/scribe-build.log 2>&1 || { tail -60 /tmp/scribe-build.log; exit 1; }

# Verify version
BUILT_VERSION=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleShortVersionString)
BUILT_BUILD=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleVersion)
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
    echo "✗ Built CFBundleShortVersionString=$BUILT_VERSION, expected $VERSION. Bump MARKETING_VERSION first."
    exit 1
fi

# Verify the cert that actually got used on the main binary
APP_CODESIGN=$(codesign -dvv "$APP_PATH" 2>&1)
if ! grep -q "Authority=Developer ID Application" <<<"$APP_CODESIGN"; then
    echo "✗ App was not signed with Developer ID Application. Check Xcode signing settings."
    grep Authority <<<"$APP_CODESIGN"
    exit 1
fi

# ----- Re-sign Sparkle's bundled helpers with our Developer ID -----
# Sparkle ships pre-signed XPC services + helpers. Notarization rejects them
# because they're signed by the Sparkle team's cert, not ours. Sign inside-out.
echo "▶ Re-signing Sparkle helpers with Developer ID..."
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"

# Extract main app entitlements first so we can re-apply when we re-sign the .app.
# Strip com.apple.security.get-task-allow defensively — notarization rejects it.
ENTITLEMENTS_TMP=$(mktemp -t scribe-entitlements.XXXXXX.plist)
codesign -d --entitlements "$ENTITLEMENTS_TMP" --xml "$APP_PATH" 2>/dev/null || true
if [[ -s "$ENTITLEMENTS_TMP" ]]; then
    python3 -c "
import plistlib, sys
with open('$ENTITLEMENTS_TMP', 'rb') as f:
    e = plistlib.load(f)
removed = e.pop('com.apple.security.get-task-allow', None)
with open('$ENTITLEMENTS_TMP', 'wb') as f:
    plistlib.dump(e, f)
if removed is not None:
    print('  ✓ stripped get-task-allow from re-sign entitlements', file=sys.stderr)
"
else
    echo "✗ Built .app has no entitlements — sandbox/audio-input/network.client are required"
    exit 1
fi

for helper in \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FW/Versions/B/Updater.app" \
    "$SPARKLE_FW/Versions/B/Autoupdate" \
    "$SPARKLE_FW"; do
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp --options runtime "$helper"
done

# Re-sign the main app last (inner re-signs invalidate the outer signature).
codesign --force --sign "$CODESIGN_IDENTITY" --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS_TMP" \
    "$APP_PATH"
rm -f "$ENTITLEMENTS_TMP"

# Sanity: app must still be Developer ID-signed and Gatekeeper-acceptable
codesign --verify --verbose=2 --deep --strict "$APP_PATH" 2>&1 | grep -q "satisfies its Designated Requirement" \
    && echo "  ✓ deep verify passed" \
    || { echo "✗ deep codesign verify failed"; codesign --verify --verbose=4 --deep --strict "$APP_PATH"; exit 1; }

# ----- Notarize the .app -----
echo "▶ Submitting to Apple notary service (this can take 5–15 minutes)..."
ZIP=/tmp/scribe-notarize-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"
NOTARIZE_JSON=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
rm "$ZIP"
NOTARIZE_STATUS=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['status'])" "$NOTARIZE_JSON")
NOTARIZE_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$NOTARIZE_JSON")
if [[ "$NOTARIZE_STATUS" != "Accepted" ]]; then
    echo "✗ Notarization $NOTARIZE_STATUS for submission $NOTARIZE_ID. Log:"
    xcrun notarytool log "$NOTARIZE_ID" --keychain-profile "$NOTARY_PROFILE"
    exit 1
fi
echo "  ✓ Notarization Accepted (id=$NOTARIZE_ID)"

# ----- Staple the .app -----
echo "▶ Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH" || { echo "✗ Staple validation failed"; exit 1; }
SPCTL_OUT=$(spctl -a -vv -t exec "$APP_PATH" 2>&1 || true)
grep -q "accepted" <<<"$SPCTL_OUT" || { echo "✗ spctl rejected the .app: $SPCTL_OUT"; exit 1; }

# ----- Build DMG (with stapled .app) -----
echo "▶ Building DMG..."
sed -i.bak "s|^DMG_NAME=.*|DMG_NAME=\"$DMG\"|" create-dmg.sh && rm create-dmg.sh.bak
rm -f "$DMG"
./create-dmg.sh "$APP_PATH" > /dev/null

# ----- Sign the DMG itself with Developer ID -----
echo "▶ Signing DMG..."
codesign --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
DMG_VERIFY=$(codesign --verify --verbose=2 "$DMG" 2>&1 || true)
grep -q "valid on disk" <<<"$DMG_VERIFY" || { echo "✗ DMG signature invalid: $DMG_VERIFY"; exit 1; }

DMG_SIZE=$(stat -f%z "$DMG")

# ----- Sparkle sign_update on the final, stapled DMG -----
echo "▶ Signing update for Sparkle..."
SIGN_OUTPUT=$(./tools/bin/sign_update "$DMG")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
[[ -n "$ED_SIGNATURE" ]] || { echo "✗ Could not parse Sparkle signature from: $SIGN_OUTPUT"; exit 1; }

# ----- Update appcast -----
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
ENCLOSURE_URL="https://github.com/sohailmamdani/scribe/releases/download/$TAG/$DMG"

echo "▶ Updating $APPCAST..."
ITEM=$(cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILT_BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>$RELEASE_NOTES_URL</sparkle:releaseNotesLink>
            <enclosure url="$ENCLOSURE_URL" length="$DMG_SIZE" type="application/octet-stream" sparkle:edSignature="$ED_SIGNATURE"/>
        </item>
EOF
)
python3 -c "
import re
content = open('$APPCAST').read()
new_item = '''$ITEM'''
# If an entry for this version already exists, replace it; otherwise insert after <language>.
existing_pattern = r'        <item>\s*<title>Version $VERSION</title>.*?</item>\n?'
if re.search(existing_pattern, content, flags=re.DOTALL):
    content = re.sub(existing_pattern, new_item + '\n', content, flags=re.DOTALL)
else:
    content = re.sub(r'(<language>en</language>)', r'\1\n' + new_item, content, count=1)
open('$APPCAST', 'w').write(content)
"

# ----- Tag, push, release -----
echo "▶ Committing appcast and tagging..."
git add "$APPCAST" create-dmg.sh
git commit -m "Release $TAG"
git tag "$TAG"
git push origin main "$TAG"

echo "▶ Creating GitHub release..."
gh release create "$TAG" \
    --title "Scribe $VERSION" \
    --notes-file <(cat <<EOF
Notarized & stapled. Auto-update: existing users on $TAG or later will be offered this build via the in-app updater (or **Scribe → Check for Updates…**).

Download \`$DMG\` below if installing manually.
EOF
) \
    "$DMG"

echo
echo "✓ Released $TAG"
echo "  Appcast: https://sohailmamdani.github.io/scribe/appcast.xml"
echo "  Release: $RELEASE_NOTES_URL"
