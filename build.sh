#!/bin/bash
# Build Disk Space Manager into a native macOS .app bundle.
# Requires the Swift toolchain that ships with Xcode / Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Disk Space Manager"
BUNDLE_ID="com.free.diskspacemanager"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
BIN="$MACOS_DIR/DiskSpaceManager"

echo "→ Cleaning…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "→ Compiling Swift (optimized)…"
swiftc -O -parse-as-library \
    -framework SwiftUI -framework AppKit \
    -o "$BIN" \
    Sources/DiskSpaceManager.swift

echo "→ Writing Info.plist…"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>DiskSpaceManager</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key><string>Free &amp; open. No license.</string>
</dict>
</plist>
PLIST

echo "→ Code-signing (ad-hoc, so macOS remembers folder permissions)…"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || \
    echo "  (ad-hoc signing skipped — app still runs)"

echo ""
echo "✓ Built: $APP_DIR"
echo ""
echo "Run it:        open \"$APP_DIR\""
echo "Install it:    cp -r \"$APP_DIR\" /Applications/"
