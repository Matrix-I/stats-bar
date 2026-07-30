#!/bin/bash
# build_dmg.sh — builds StatsBar.app and packages it into a distributable StatsBar-v<version>.dmg
# Requires: Xcode Command Line Tools (xcode-select --install)

set -euo pipefail
cd "$(dirname "$0")"

APP=StatsBar
VOL="$APP"

# 0. Never package a red suite. This is the only real gate on the release path: CI reports on pushes
#    to main but does not block them, and update_appcast.sh publishes straight to the feed that every
#    installed copy polls, so there is no staging step between a bad build and users.
#
#    The bare exit code is not enough, for the reason ci.yml gives about its own copy of this check: a
#    test target that compiles but contains no tests exits 0, so "everything passed" and "nothing ran"
#    are the same signal. Asserting a non-zero test count is what separates them, and the release path
#    has no business trusting a weaker signal than CI already refuses to trust.
#    STAGEROOT is in the same trap even though it is assigned much later: `${STAGEROOT:-}` keeps that safe
#    under set -u, and it means a failure between `cp -R` and `rm -rf` no longer leaks a full copy of the
#    .app into /var/folders with nothing to reap it.
TESTLOG="$(mktemp -t statsbar-tests)"
trap 'rm -f "$TESTLOG"; rm -rf "${STAGEROOT:-}"' EXIT
./run_tests.sh | tee "$TESTLOG"
# `tests?` and `suites?`, because swift-testing pluralizes: a run of exactly one test says "1 test in 1
# suite passed". The count still has to be non-zero — that is the whole point — but the assertion must not
# also reject a legitimately small run, which is a green suite refused for its grammar.
grep -qE 'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' "$TESTLOG" || {
    echo "❌ run_tests.sh exited 0 but reported no passing test run — refusing to package." >&2
    exit 1
}

# 1. Build the .app bundle (compile + bundle + sign). --no-launch: just package it, don't relaunch the
#    local build (that only makes sense for a dev build, not DMG packaging).
./build_app.sh --no-launch

# 2. The version is read out of the bundle that was just built, never passed in. Every other name in a
#    release derives from this one string — the DMG, the git tag, the GitHub asset, the appcast enclosure
#    URL — and the way that used to go wrong was a hardcoded StatsBar.dmg plus a manual `mv` to the
#    versioned name: a step no script performed and no document mentioned except one usage example.
PLIST="$APP.app/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DMG="$APP-v$SHORT_VERSION.dmg"

# A -SNAPSHOT build is packaged on purpose — that is how a DMG gets tested before a release is cut — but
# it must never reach the feed. Saying so here is cheap; update_appcast.sh is what actually refuses it,
# because that is the step with consequences for everyone else.
case "$SHORT_VERSION" in
    *-SNAPSHOT)
        echo ""
        echo "⚠️  Packaging a SNAPSHOT ($SHORT_VERSION) — fine for testing, NOT publishable."
        echo "    Drop the suffix in build_app.sh first if this is meant to be a release."
        ;;
esac

# 3. Prove the bundle is sealed before it goes into a disk image. build_app.sh tolerates a codesign
#    failure on its ad-hoc branch (`|| echo`), so without this a failure printed one warning line and the
#    script still exited 0 with "✅ Done" — shipping a bundle whose Info.plist is unsealed, or whose
#    embedded Sparkle.framework kept the upstream signature while the host was re-signed. The second
#    breaks nested-code validation and takes Sparkle's own Updater.app and XPC services with it: auto
#    update silently dead for that release, and the app itself looks perfect. CI has checked exactly this
#    since 13d90fb, but CI never builds a DMG, so the check did not exist where it mattered.
#
#    What it proves is that the bundle is internally consistent and sealed — not that the signature is
#    trusted, notarized, or made with any particular identity. Those are separate questions; the identity
#    actually used is read back and reported below.
echo "🔍 Verifying the signature ..."
codesign --verify --deep --strict "$APP.app"

# What it was actually signed WITH, read back off the bundle rather than assumed. This script used to
# close by announcing "the app is ad-hoc signed" unconditionally, and that was false for v2.12.0, which
# shipped Authority=StatsBar Local — so the release script told the operator the opposite of what it had
# just produced, which is a large part of why that change went a whole release unnoticed.
if codesign -dvvv "$APP.app" 2>&1 | grep -q "Signature=adhoc"; then
    SIGNED_AS="ad-hoc"
else
    SIGNED_AS="$(codesign -dvvv "$APP.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    [ -n "$SIGNED_AS" ] || SIGNED_AS="unknown identity"
fi

# 4. Stage the disk-image contents: the app + a drag-to-install shortcut to /Applications
STAGEROOT="$(mktemp -d)"
STAGE="$STAGEROOT/$VOL"
mkdir -p "$STAGE"
cp -R "$APP.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 5. Create a compressed, read-only disk image from the staging folder
echo "💿 Building $DMG ..."
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo ""
echo "✅ Done: $DMG"
echo "   Version : $SHORT_VERSION  (CFBundleVersion $BUNDLE_VERSION — the key Sparkle compares)"
echo "   Signed  : $SIGNED_AS"
echo "   Install : open \"$DMG\", then drag $APP into the Applications folder."
if [ "$SIGNED_AS" = "ad-hoc" ]; then
    echo ""
    echo "   ⚠️  Ad-hoc: the designated requirement is the binary's own cdhash, which changes on every"
    echo "       build, so macOS treats each release as a brand new app and re-prompts for Location and"
    echo "       Bluetooth. A stable identity avoids that — see build_app.sh's signing header."
fi
echo ""
echo "   ⚠️  Not notarized, so on another Mac Gatekeeper blocks the first launch. Fix it one of these"
echo "       ways after copying $APP into /Applications:"
echo "         • Right-click $APP → Open → Open   (per-user, once; on macOS 15+ the confirmation moved"
echo "           to System Settings ▸ Privacy & Security ▸ \"Open Anyway\"), or"
echo "         • xattr -dr com.apple.quarantine /Applications/$APP.app"
