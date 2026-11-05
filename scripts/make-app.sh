#!/usr/bin/env bash
# make-app.sh — wrap the built voicebridge-gui binary into a launchable .app bundle.
#
# Usage: scripts/make-app.sh [debug|release]
#
# The bundle is ad-hoc signed so the microphone prompt has a stable identity.
# For a *shipping* build you also want a Developer ID certificate and
# notarization (see .github/workflows/release.yml).
set -euo pipefail
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The version comes from the VERSION file (single source of truth).
VERSION="$(cat VERSION 2>/dev/null || echo "1.2.0")"

swift build -c "$CONFIG"
BIN=".build/$CONFIG/voicebridge-gui"
[ -x "$BIN" ] || { echo "binary missing: $BIN" >&2; exit 1; }

APP="$ROOT/Build/VoiceBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/voicebridge-gui"

# The icon. `scripts/make-icon.sh` builds it from the two master PNGs in
# Resources/; both the .icns and the PNGs are committed, so a plain build needs
# no ImageMagick, no Pillow and no network.
ICON="$ROOT/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: $ICON is missing; the app will use the generic icon" >&2
  echo "         run: scripts/make-icon.sh" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>VoiceBridge</string>
    <key>CFBundleDisplayName</key>     <string>VoiceBridge</string>
    <key>CFBundleIdentifier</key>      <string>local.voicebridge.app</string>
    <key>CFBundleExecutable</key>      <string>voicebridge-gui</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>VoiceBridge uses the microphone for on-device speech-to-text.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc codesign so the mic/accessibility prompts get a stable identity.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP  (version $VERSION)"
