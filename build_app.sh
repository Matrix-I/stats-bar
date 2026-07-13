#!/bin/bash
# build_app.sh — compiles BatteryBar.swift and packages it into BatteryBar.app
# Requires: Xcode Command Line Tools (xcode-select --install)

set -euo pipefail
cd "$(dirname "$0")"

APP=BatteryBar

echo "🔨 Compiling $APP.swift ..."
swiftc -O -parse-as-library "$APP.swift" -o "$APP"

echo "📦 Building the app bundle ..."
rm -rf "$APP.app"
mkdir -p "$APP.app/Contents/MacOS"
mv "$APP" "$APP.app/Contents/MacOS/$APP"

cat > "$APP.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>BatteryBar</string>
    <key>CFBundleIdentifier</key>       <string>local.batterybar</string>
    <key>CFBundleName</key>             <string>BatteryBar</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign (not required for a local build, but cleaner)
codesign --force -s - "$APP.app" 2>/dev/null || true

echo ""
echo "✅ Done: $APP.app"
echo "   Run it         : open $APP.app"
echo "   Launch at login: System Settings → General → Login Items → add $APP.app"
