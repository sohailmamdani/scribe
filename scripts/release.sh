#!/bin/bash
# Cuts a new release: builds, signs, updates the appcast, tags, and publishes
# a GitHub release with the DMG attached.
#
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 1.6
#
# Pre-requisites:
#   - MARKETING_VERSION + CURRENT_PROJECT_VERSION already bumped in
#     Scribe.xcodeproj/project.pbxproj
#   - Sparkle CLI tools fetched: ./scripts/install-tools.sh
#   - Sparkle private key in macOS Keychain (created via generate_keys)
#   - gh CLI authenticated

set -euo pipefail

VERSION="${1:?Usage: $0 <version>  (e.g. 1.6)}"
TAG="v$VERSION"
DMG="Scribe-$VERSION.dmg"
APP_PATH="build/release/Build/Products/Release/Scribe.app"
APPCAST="docs/appcast.xml"
RELEASE_NOTES_URL="https://github.com/sohailmamdani/scribe/releases/tag/$TAG"

# 0. Sanity checks
[[ -x "tools/bin/sign_update" ]] || { echo "Sparkle tools missing — run scripts/install-tools.sh"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree dirty — commit or stash first"; exit 1; }

echo "▶ Building Scribe.app (Release)..."
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath build/release \
    clean build > /tmp/scribe-build.log 2>&1 || { tail -50 /tmp/scribe-build.log; exit 1; }

BUILT_VERSION=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleShortVersionString)
BUILT_BUILD=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleVersion)
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
    echo "ERROR: built CFBundleShortVersionString=$BUILT_VERSION, expected $VERSION."
    echo "Bump MARKETING_VERSION in project.pbxproj before releasing."
    exit 1
fi

echo "▶ Building DMG..."
sed -i.bak "s|^DMG_NAME=.*|DMG_NAME=\"$DMG\"|" create-dmg.sh && rm create-dmg.sh.bak
rm -f "$DMG"
./create-dmg.sh "$APP_PATH" > /dev/null
DMG_SIZE=$(stat -f%z "$DMG")

echo "▶ Signing update..."
SIGN_OUTPUT=$(./tools/bin/sign_update "$DMG")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
[[ -n "$ED_SIGNATURE" ]] || { echo "Could not parse signature from: $SIGN_OUTPUT"; exit 1; }

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
# Insert new <item> right after <language>en</language>
python3 -c "
import sys, re
content = open('$APPCAST').read()
new_item = '''$ITEM'''
content = re.sub(r'(<language>en</language>)', r'\1\n' + new_item, content, count=1)
open('$APPCAST', 'w').write(content)
"

echo "▶ Committing appcast and tagging..."
git add "$APPCAST" create-dmg.sh
git commit -m "Release $TAG"
git tag "$TAG"
git push origin main "$TAG"

echo "▶ Creating GitHub release..."
gh release create "$TAG" \
    --title "Scribe $VERSION" \
    --notes-file <(cat <<EOF
Auto-update: existing $TAG users will be offered this build via the in-app updater (or **Scribe → Check for Updates…**).

Download \`$DMG\` below if installing manually.
EOF
) \
    "$DMG"

echo "✓ Released $TAG"
echo "  Appcast: https://sohailmamdani.github.io/scribe/appcast.xml"
echo "  Release: $RELEASE_NOTES_URL"
