#!/bin/bash
# build_dmg.sh — builds StatsBar.app and packages it into a distributable StatsBar.dmg
# Requires: Xcode Command Line Tools (xcode-select --install)

set -euo pipefail
cd "$(dirname "$0")"

APP=StatsBar
DMG="$APP.dmg"
VOL="$APP"

# 1. Build the .app bundle (compile + bundle + ad-hoc sign). --no-launch: just package it,
#    don't relaunch the local build (that only makes sense for a dev build, not DMG packaging).
./build_app.sh --no-launch

# 2. Stage the disk-image contents: the app + a drag-to-install shortcut to /Applications
STAGEROOT="$(mktemp -d)"
STAGE="$STAGEROOT/$VOL"
mkdir -p "$STAGE"
cp -R "$APP.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. Create a compressed, read-only disk image from the staging folder
echo "💿 Building $DMG ..."
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

rm -rf "$STAGEROOT"

echo ""
echo "✅ Done: $DMG"
echo "   Install : open \"$DMG\", then drag $APP into the Applications folder."
echo ""
echo "   ⚠️  The app is ad-hoc signed (not notarized), so on another Mac Gatekeeper"
echo "       will block the first launch. Fix it one of these ways after copying"
echo "       $APP to /Applications:"
echo "         • Right-click $APP → Open → Open   (per-user, once), or"
echo "         • xattr -dr com.apple.quarantine /Applications/$APP.app"
