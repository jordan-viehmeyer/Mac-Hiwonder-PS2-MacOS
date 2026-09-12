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
    <key>NSHumanReadableCopyright</key>
    <string>PolyForm Noncommercial 1.0.0 — noncommercial use only</string>

    <!--
      Exactly two permissions, and nothing else.

      NSInputMonitoringUsageDescription is the only usage string present: it is shown in
      the TCC prompt, so it should say why rather than letting macOS ask blankly.

      Accessibility has no usage-string key; it is requested at runtime, and only when the
      user presses Start. Reading the pad — live view, calibration, the wizard — needs
      Input Monitoring alone.

      Deliberately absent: NSAppleEventsUsageDescription (NSWorkspace.open needs no Apple
      Events), and any camera, microphone, network, file, contacts, location or Bluetooth
      key. The app makes no network connections and reads no files outside its own config
      folder.
    -->
    <key>NSInputMonitoringUsageDescription</key>
    <string>ps2mc reads your PS2 controller so it can drive the keyboard and mouse.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# TCC identifies an app by its code signature, and stores that requirement when you grant a
# permission. Ad-hoc signing produces a requirement that is just a hash of the binary, so
# every rebuild looks like a different app and granted permissions stop applying. A local
# signing certificate makes the requirement name the certificate instead, so grants survive
# rebuilds -- create one with scripts/make-signing-identity.sh.
IDENTITY="ps2mc Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> Signing with \"$IDENTITY\""
  codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "==> Signing (ad-hoc)"
  codesign --force --deep --sign - --timestamp=none "$APP"
fi
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

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  cat <<'NOTE'

Note: this build is ad-hoc signed, so macOS identifies it by a hash of the binary. After
any rebuild it looks like a new app and you must grant the two permissions again -- remove
the stale ps2mc entry in System Settings first, or the new one will not take.

To make grants survive rebuilds:  ./scripts/make-signing-identity.sh
NOTE
fi
