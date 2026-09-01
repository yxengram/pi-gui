#!/bin/bash
# Builds PiGUI and assembles a launchable .app bundle.
#
# SwiftPM produces a bare executable; macOS needs a bundle with an Info.plist before
# the app can own a menu bar, appear in the Dock, or be launched from Finder.
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="pi-gui"
BUNDLE_ID="works.earendil.pi-gui"
VERSION="$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$PACKAGE_DIR/../../package.json" | head -1)"
VERSION="${VERSION:-0.0.0}"

cd "$PACKAGE_DIR"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PACKAGE_DIR/build/$APP_NAME.app"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/PiGUI" "$APP_DIR/Contents/MacOS/$APP_NAME"

# SwiftPM emits resource bundles beside the binary; they must travel with the app.
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>pi-gui</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- A regular app owns a menu bar and a Dock icon; without this it launches
         as a background process with neither. -->
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> Built $APP_DIR"
echo "    open \"$APP_DIR\""
