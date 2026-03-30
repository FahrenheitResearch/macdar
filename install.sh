#!/bin/bash
set -e

echo "Installing macdar..."

# Download latest release
TMPDIR=$(mktemp -d)
ZIP="$TMPDIR/macdar-macos.zip"
curl -sL "https://github.com/FahrenheitResearch/macdar/releases/latest/download/macdar-macos.zip" -o "$ZIP"

# Unzip
cd "$TMPDIR"
unzip -q "$ZIP"

# Remove quarantine flag (prevents Gatekeeper "damaged" error)
xattr -cr macdar.app

# Move to Applications
if [ -d /Applications/macdar.app ]; then
    echo "Removing old version..."
    rm -rf /Applications/macdar.app
fi
mv macdar.app /Applications/

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "Installed to /Applications/macdar.app"
echo "Opening macdar..."
open /Applications/macdar.app
