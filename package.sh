#!/bin/bash
set -e
cd "$(dirname "$0")"

# Build first
./build.sh

APP="macdar.app"
rm -rf "$APP"

# Create .app bundle structure
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy binary
cp build/macdar "$APP/Contents/MacOS/macdar"

# Copy metallib if it exists
if [ -f build/default.metallib ]; then
    cp build/default.metallib "$APP/Contents/MacOS/default.metallib"
fi

# Copy shader sources as fallback (for runtime compilation)
mkdir -p "$APP/Contents/Resources/shaders"
cp src/metal/metal_common.h "$APP/Contents/Resources/shaders/"
cp src/metal/renderer.metal "$APP/Contents/Resources/shaders/"
cp src/metal/volume3d.metal "$APP/Contents/Resources/shaders/"
cp src/metal/gpu_pipeline.metal "$APP/Contents/Resources/shaders/"

# Info.plist
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>macdar</string>
    <key>CFBundleIdentifier</key>
    <string>com.fahrenheitresearch.macdar</string>
    <key>CFBundleName</key>
    <string>macdar</string>
    <key>CFBundleDisplayName</key>
    <string>macdar</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# Entitlements for hardened runtime (required for notarization)
cat > /tmp/macdar-entitlements.plist << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENT

# Code sign with Developer ID (or Apple Development if no Developer ID yet)
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi

if [ -z "$IDENTITY" ]; then
    echo "No signing identity found. Ad-hoc signing..."
    codesign --force --deep -s - "$APP"
else
    echo "Signing with: $IDENTITY"
    codesign --force --deep --options runtime \
        --entitlements /tmp/macdar-entitlements.plist \
        -s "$IDENTITY" "$APP"
fi

# Create ZIP for notarization + distribution
ZIP="macdar-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Notarize if credentials are available
if xcrun notarytool history --keychain-profile "macdar" &>/dev/null; then
    echo ""
    echo "Submitting for notarization..."
    xcrun notarytool submit "$ZIP" --keychain-profile "macdar" --wait
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP"
    # Re-zip with stapled ticket
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo ""
    echo "Notarized and stapled."
else
    echo ""
    echo "Skipping notarization (no keychain profile 'macdar' found)."
    echo "Run: xcrun notarytool store-credentials macdar"
fi

echo ""
echo "Packaged: $APP"
echo "Distribution: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo ""
echo "Users can unzip and double-click macdar.app to run."
