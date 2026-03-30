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

# Create ZIP for distribution
ZIP="macdar-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "Packaged: $APP"
echo "Distribution: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo ""
echo "Users can unzip and double-click macdar.app to run."
