#!/bin/bash
# build_app.sh — compiles the Sources/ tree and packages it into BatteryBar.app
# Requires: Xcode Command Line Tools (xcode-select --install)

set -euo pipefail
cd "$(dirname "$0")"

APP=BatteryBar

# By default, relaunch the app once it's built so "build finished" actually means "the new
# version is running". Pass --no-launch to only produce the bundle (used by build_dmg.sh).
RELAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --no-launch) RELAUNCH=0 ;;
    esac
done

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

# Force LaunchServices to re-register this exact bundle and drop any cached icon render, so the
# freshly built AppIcon appears immediately (in Finder and in notifications posted by the app)
# instead of a stale/generic placeholder. lsregister is the private LaunchServices support tool;
# touch bumps mtime so IconServices re-rasterizes. Best-effort — never fail the build over it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$PWD/$APP.app" 2>/dev/null || true
touch "$APP.app"

echo ""
echo "✅ Done: $APP.app"

if [ "$RELAUNCH" -eq 1 ]; then
    echo "🔄 Relaunching $APP ..."
    # Quit any running copy first — a menu-bar (LSUIElement) app has no window for `open` to
    # activate, so without this it would just no-op against the old instance and the new build
    # would never come up.
    pkill -x "$APP" 2>/dev/null || true
    # LaunchServices can briefly return -600 (procNotFound) right after the old instance dies,
    # so a single `open` here fails and the app looks like it "won't start". Retry until it takes.
    launched=0
    for _ in 1 2 3 4 5; do
        sleep 0.6
        if open "$APP.app" 2>/dev/null; then launched=1; break; fi
    done
    if [ "$launched" -eq 1 ]; then
        echo "✅ $APP is running — look for the battery glyph in the menu bar."
    else
        echo "⚠️  Auto-launch didn't take — run it manually: open $APP.app"
    fi
else
    echo "   Run it         : open $APP.app"
    echo "   Launch at login: System Settings → General → Login Items → add $APP.app"
fi
