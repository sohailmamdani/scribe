#!/bin/bash

# Build script for Scribe macOS app

set -e

echo "🔨 Building Scribe..."

# Clean build directory
rm -rf build

# Build the app
xcodebuild \
    -project Scribe.xcodeproj \
    -scheme Scribe \
    -configuration Release \
    -derivedDataPath build \
    clean build

echo "✅ Build complete!"
echo ""
echo "App location: $(pwd)/build/Build/Products/Release/Scribe.app"
echo ""
echo "To run the app:"
echo "  open build/Build/Products/Release/Scribe.app"
echo ""
echo "To install to Applications:"
echo "  cp -r build/Build/Products/Release/Scribe.app /Applications/"
