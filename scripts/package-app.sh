#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/MLXDashboard.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

cd "$ROOT"
swift build -c release --product MLXDashboard

rm -rf "$APP"
mkdir -p "$MACOS"
cp ".build/release/MLXDashboard" "$MACOS/MLXDashboard"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MLXDashboard</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.MLXDashboard</string>
  <key>CFBundleName</key>
  <string>MLXDashboard</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST

echo "$APP"
