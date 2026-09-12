#!/usr/bin/env bash
# Build PS2MC.app.
#
# There is no Xcode here, only Command Line Tools, so the bundle is assembled by hand:
# SwiftPM produces the executable, and this lays out Contents/ around it. That is all an
# .app is -- a directory with a known shape and an Info.plist.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="PS2MC"
BUNDLE_ID="family.theviehmeyers.ps2mc"
VERSION="1.0.0"
DEST="${DEST:-$REPO_ROOT/build}"
APP="$DEST/$APP_NAME.app"

echo "==> Building (release)"
swift build -c release --product PS2MCApp
swift build -c release --product ps2mc
BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Verifying the engine"
"$BIN_PATH/ps2mc" selftest

echo "==> Laying out $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/PS2MCApp" "$APP/Contents/MacOS/$APP_NAME"
# The CLI ships inside the bundle so both frontends are always the same build, but it goes
# in Resources rather than MacOS: the volume is case-insensitive, so MacOS/ps2mc and
# MacOS/PS2MC are the same path and the second copy silently clobbers the app binary.
cp "$BIN_PATH/ps2mc" "$APP/Contents/Resources/ps2mc"

# Prove the app binary is still the one we built. Comparing bytes rather than running it:
# the app binary is a GUI app and would launch rather than answer a probe.
if ! cmp -s "$BIN_PATH/PS2MCApp" "$APP/Contents/MacOS/$APP_NAME"; then
  echo "error: $APP_NAME executable does not match the built app -- something overwrote it" >&2
  exit 1
fi

echo "==> Generating icon"
ICONSET="$(mktemp -d)/$APP_NAME.iconset"
swiftc -O "$REPO_ROOT/scripts/make-icon.swift" -o "$(dirname "$ICONSET")/mkicon"
"$(dirname "$ICONSET")/mkicon" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>ps2mc</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>              <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSHumanReadableCopyright</key>      <string>MIT licensed</string>
    <!-- Shown in the TCC prompts, so say why rather than letting macOS ask blankly. -->
    <key>NSInputMonitoringUsageDescription</key>
    <string>ps2mc reads your PS2 controller so it can drive the keyboard and mouse.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>ps2mc opens System Settings to the panes where you grant its permissions.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# TCC identifies an app by its code signature. An unsigned bundle gets a fresh identity on
# every rebuild, so granted permissions silently stop applying. Ad-hoc signing is enough to
# keep that identity stable on one machine.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature OK"

echo
echo "Built $APP"
echo
echo "Install it, then grant permissions to the app itself:"
echo "  cp -R \"$APP\" /Applications/"
echo "  open /Applications/$APP_NAME.app"
echo
echo "Keep it in /Applications -- macOS pins Input Monitoring and Accessibility to the"
echo "app's path, so moving it later means granting them again."
