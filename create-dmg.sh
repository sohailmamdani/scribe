#!/bin/bash

# Script to create a distributable DMG for Scribe

APP_PATH="$1"
DMG_NAME="Scribe-1.6.dmg"
VOLUME_NAME="Scribe"

if [ -z "$APP_PATH" ]; then
    echo "Usage: ./create-dmg.sh /path/to/Scribe.app"
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH"
    exit 1
fi

# Create temporary directory
TMP_DIR=$(mktemp -d)
echo "Creating DMG in temporary directory: $TMP_DIR"

# Copy app to temp directory
cp -R "$APP_PATH" "$TMP_DIR/"

# Create symlink to Applications folder
ln -s /Applications "$TMP_DIR/Applications"

# Create DMG
echo "Creating DMG..."
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$TMP_DIR" \
    -ov -format UDZO \
    "$DMG_NAME"

# Clean up
rm -rf "$TMP_DIR"

echo "✅ DMG created: $DMG_NAME"
echo ""
echo "Users can:"
echo "1. Download $DMG_NAME"
echo "2. Open it"
echo "3. Drag Scribe.app to Applications folder"
