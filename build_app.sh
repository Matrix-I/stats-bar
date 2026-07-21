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

# Sparkle (auto-update) is linked in. Fetch the pinned framework if it's not vendored yet — this is a
# no-op on subsequent builds, so normal rebuilds don't touch the network.
./fetch_sparkle.sh

echo "🔨 Compiling $APP (Sources/*.swift) ..."
# Compile every source file in Sources/ as one module. The other top-level *.swift files
# (icon_gen.swift, screeninfo.swift) are standalone tools and are deliberately excluded.
# -F/-framework link Sparkle; the added @rpath resolves it from Contents/Frameworks at runtime.
SOURCES=$(find Sources -name '*.swift')
# shellcheck disable=SC2086
swiftc -O -parse-as-library $SOURCES \
    -F "$PWD/Frameworks" -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "$APP"

echo "📦 Building the app bundle ..."
rm -rf "$APP.app"
mkdir -p "$APP.app/Contents/MacOS" "$APP.app/Contents/Resources"
mv "$APP" "$APP.app/Contents/MacOS/$APP"

# Embed Sparkle so the linked @rpath (@executable_path/../Frameworks) resolves at runtime. -R keeps
# the framework's version symlinks intact (codesign requires the canonical Versions/Current layout).
mkdir -p "$APP.app/Contents/Frameworks"
cp -R Frameworks/Sparkle.framework "$APP.app/Contents/Frameworks/"

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
    <key>CFBundleShortVersionString</key><string>2.3.0</string>
    <!-- Sparkle compares CFBundleVersion between the running app and the appcast to decide whether an
         update is newer, so it must be bumped alongside CFBundleShortVersionString on every release. -->
    <key>CFBundleVersion</key>          <string>2.3.0</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <!-- Sparkle auto-update. SUFeedURL is the appcast (kept in the repo, served raw from GitHub);
         SUPublicEDKey is the EdDSA public key whose private half (in the release machine's keychain)
         signs each update — Sparkle refuses any download that doesn't verify against it. -->
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/Matrix-I/stats-bar/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>T9m2CL18FlN4xB3BR8rb6XNk7kFTCk4IWMIXlcp7WGE=</string>
    <!-- The Network item reads the Wi-Fi network name (SSID), which macOS 14+ only reveals to apps
         holding Location Services authorization. Both keys are provided so the prompt shows on old
         and new systems; nothing else in the app uses location. -->
    <key>NSLocationUsageDescription</key>
    <string>StatsBar shows the name of the Wi-Fi network you're connected to.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>StatsBar shows the name of the Wi-Fi network you're connected to.</string>
    <!-- The Bluetooth item reads per-device battery levels via IOBluetoothDevice for accessories
         (e.g. BLE mice) whose levels system_profiler doesn't report. macOS aborts the process on
         first Bluetooth access unless this key is present, so it is mandatory. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>StatsBar shows the battery level of your connected Bluetooth devices.</string>
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
#
# NOTE: we look the identity up WITHOUT `find-identity -v`. A self-signed cert isn't trusted as a
# root, so the `-v` (valid) filter hides it — but codesign signs with it fine anyway (signing needs
# the private key, not a trusted chain), and TCC keys permissions to the cert hash regardless of
# trust. So requiring `-v` here would needlessly fall back to ad-hoc for exactly the self-signed
# local cert this is meant to use. We still confirm a private key exists (an identity, not a bare
# cert) by matching the numbered "N) <hash> "<name>"" identity line.
SIGN_IDENTITY="${STATSBAR_SIGN_IDENTITY:-StatsBar Local}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""; then
    echo "🔏 Signing with stable identity: $SIGN_IDENTITY (permissions persist across upgrades)"
    SIGN_TO="$SIGN_IDENTITY"
else
    echo "🔏 No stable signing identity ('$SIGN_IDENTITY') — ad-hoc signing."
    echo "   Permissions (e.g. Location) will re-prompt after each rebuild. See build_app.sh header."
    SIGN_TO="-"
fi

# Sign inside-out: the embedded Sparkle framework first (it nests Updater.app + XPC services, which
# codesign --deep signs with our identity so Sparkle's runtime sees a matching signature), then seal
# the app bundle around it. Ad-hoc ('-') signing is tolerated on failure; a real identity must succeed.
SPARKLE_FW="$APP.app/Contents/Frameworks/Sparkle.framework"
if [ "$SIGN_TO" = "-" ]; then
    codesign --force --deep -s - "$SPARKLE_FW" 2>/dev/null || true
    codesign --force -s - "$APP.app" 2>/dev/null || true
else
    codesign --force --deep -s "$SIGN_TO" "$SPARKLE_FW"
    codesign --force -s "$SIGN_TO" "$APP.app"
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
