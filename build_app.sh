#!/bin/bash
# build_app.sh — compiles the Sources/ tree and packages it into BatteryBar.app
# Requires: Xcode Command Line Tools (xcode-select --install)

set -euo pipefail
cd "$(dirname "$0")"

APP=BatteryBar

echo "🔨 Compiling $APP (Sources/*.swift) ..."
# Compile every source file in Sources/ as one module. The other top-level *.swift files
# (icon_gen.swift, screeninfo.swift) are standalone tools and are deliberately excluded.
SOURCES=$(find Sources -name '*.swift')
# shellcheck disable=SC2086
swiftc -O -parse-as-library $SOURCES -o "$APP"

echo "📦 Building the app bundle ..."
rm -rf "$APP.app"
mkdir -p "$APP.app/Contents/MacOS" "$APP.app/Contents/Resources"
mv "$APP" "$APP.app/Contents/MacOS/$APP"

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$APP.app/Contents/Resources/AppIcon.icns"
fi

cat > "$APP.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>BatteryBar</string>
    <key>CFBundleIdentifier</key>       <string>local.batterybar</string>
    <key>CFBundleName</key>             <string>BatteryBar</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
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
