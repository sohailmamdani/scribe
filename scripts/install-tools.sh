#!/bin/bash
# Downloads Sparkle's CLI tools (generate_keys, sign_update, generate_appcast)
# into ./tools/. Idempotent — re-run to refresh.

set -euo pipefail

SPARKLE_VERSION="2.9.1"
TOOLS_DIR="tools"

if [[ -x "$TOOLS_DIR/bin/sign_update" ]]; then
    echo "Sparkle tools already present at $TOOLS_DIR/bin/. Delete and re-run to refresh."
    exit 0
fi

mkdir -p "$TOOLS_DIR"
TARBALL_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

echo "Fetching Sparkle ${SPARKLE_VERSION}..."
curl -sL "$TARBALL_URL" -o "$TOOLS_DIR/sparkle.tar.xz"
tar -xf "$TOOLS_DIR/sparkle.tar.xz" -C "$TOOLS_DIR/"
rm "$TOOLS_DIR/sparkle.tar.xz"

echo "✓ Tools installed to $TOOLS_DIR/bin/"
ls "$TOOLS_DIR/bin/"
