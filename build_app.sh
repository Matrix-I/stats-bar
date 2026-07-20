#!/bin/bash
# build_app.sh — compiles the Sources/ tree and packages it into StatsBar.app
# Requires: Xcode Command Line Tools (xcode-select --install)

set -euo pipefail
cd "$(dirname "$0")"

APP=StatsBar

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
    <key>CFBundleExecutable</key>       <string>StatsBar</string>
    <key>CFBundleIdentifier</key>       <string>local.statsbar</string>
    <key>CFBundleName</key>             <string>StatsBar</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <!-- The Network item reads the Wi-Fi network name (SSID), which macOS 14+ only reveals to apps
         holding Location Services authorization. Both keys are provided so the prompt shows on old
         and new systems; nothing else in the app uses location. -->
    <key>NSLocationUsageDescription</key>
    <string>StatsBar shows the name of the Wi-Fi network you're connected to.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>StatsBar shows the name of the Wi-Fi network you're connected to.</string>
</dict>
</plist>
PLIST

# Code signing.
#
# macOS ties granted permissions (TCC: Location — used for the Wi-Fi network name — Screen
# Recording, etc.) to the code-signing "designated requirement". An *ad-hoc* signature's requirement
# is the binary's cdhash, which changes on every build, so an ad-hoc-signed app is treated as brand
# new after each rebuild/version bump and re-prompts for permission. Signing with a *stable* identity
# keeps the requirement constant (identifier + certificate), so permissions persist across upgrades.
#
# Set STATSBAR_SIGN_IDENTITY to a code-signing certificate name to use it; a free self-signed one
# works fine for local use. To create one: Keychain Access ▸ Certificate Assistant ▸ Create a
# Certificate… → Name "StatsBar Local", Identity Type "Self Signed Root", Certificate Type
# "Code Signing". Then either `export STATSBAR_SIGN_IDENTITY="StatsBar Local"` or just name it
# that (the default below). Without a matching identity we fall back to ad-hoc (re-prompts remain).
SIGN_IDENTITY="${STATSBAR_SIGN_IDENTITY:-StatsBar Local}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "🔏 Signing with stable identity: $SIGN_IDENTITY (permissions persist across upgrades)"
    codesign --force --deep -s "$SIGN_IDENTITY" "$APP.app"
else
    echo "🔏 No stable signing identity ('$SIGN_IDENTITY') — ad-hoc signing."
    echo "   Permissions (e.g. Location) will re-prompt after each rebuild. See build_app.sh header."
    codesign --force -s - "$APP.app" 2>/dev/null || true
fi

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
