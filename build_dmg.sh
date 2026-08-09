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

# The only relation between the two keys that is ever correct: CFBundleVersion is the short version with
# any -SNAPSHOT stripped. Stripped rather than exempted, because a snapshot whose CFBundleVersion has
# quietly drifted is the state that CAUSES the failure, and exempting snapshots would leave it
# unexamined until the cut — the exact moment this check exists to be earlier than.
#
# update_appcast.sh asserts the same thing and keeps doing so; it reads the bundle inside the DMG, which
# need not be the one this run built. But that is step 5 of the release, AFTER `gh release create` has
# published the tag, the release page and the asset. Failing there means deleting a published release
# from an account only one person can write to. Failing here costs one line and a rebuild.
#
# Reachable because a fixes-only cut changes the NUMBER, not just the suffix: ee29c9a took
# 2.12.0-SNAPSHOT straight to 2.11.1 and a41ad97 took 2.13.0-SNAPSHOT to 2.12.2, both two-line edits,
# while the comment in build_app.sh says to "drop the suffix here" — singular, and true only for the
# release that keeps the number its snapshot already named.
if [ "${SHORT_VERSION%-SNAPSHOT}" != "$BUNDLE_VERSION" ]; then
    echo "❌ CFBundleVersion ($BUNDLE_VERSION) does not match CFBundleShortVersionString ($SHORT_VERSION)." >&2
    echo "   Sparkle compares CFBundleVersion, so publishing this burns the number the next release" >&2
    echo "   wants: that release would never be offered to anyone who installed this one." >&2
    echo "   Set BOTH keys in build_app.sh to the release number and rebuild." >&2
    exit 1
fi

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
#
# Read once into a variable and match on that, rather than piping into `grep -q`. Under `set -o pipefail`
# grep -q exits at its first match, codesign dies of SIGPIPE, and 141 becomes the pipeline's status — so
# for an AD-HOC bundle the ad-hoc branch was sometimes not taken at all, and the summary below reported
# "unknown identity" for a bundle it had just described correctly on the previous run. Measured at
# roughly one run in ten. The race is one-directional: with a real identity grep matches nothing, drains
# the output and never signals, so it misfired only in the direction that hides the problem.
SIGN_INFO="$(codesign -dvvv "$APP.app" 2>&1)"
case "$SIGN_INFO" in
    *"Signature=adhoc"*) SIGNED_AS="ad-hoc" ;;
    *) SIGNED_AS="$(printf '%s\n' "$SIGN_INFO" | sed -n 's/^Authority=//p' | head -1)"
       [ -n "$SIGNED_AS" ] || SIGNED_AS="unknown identity" ;;
esac

# Refuse to package an ad-hoc build for release. The signing identity IS the TCC designated requirement,
# and an ad-hoc one is the binary's own cdhash — so shipping it resets Location and Bluetooth for every
# user already on v2.11.1 or later, who then lose the Wi-Fi network name and their accessory battery
# levels until each of them re-grants by hand. There is no way to push that back from this end.
#
# Nothing downstream would have caught it: `codesign --verify` passes on an ad-hoc signature by design —
# that is what it is for — and update_appcast.sh never looks at the identity at all. CLAUDE.md records
# that this already happened once in the other direction, the identity moving from ad-hoc to StatsBar
# Local at v2.11.1 with nobody noticing for two releases.
#
# The gate belongs HERE and deliberately not in build_app.sh: a contributor without the certificate must
# still be able to build and run the app. They simply cannot cut a release with it. The override exists
# for the one legitimate case, a maintainer who has genuinely lost the certificate and accepts what it
# costs their users, and it has to be typed out in full so it cannot happen by accident.
if [ "$SIGNED_AS" = "ad-hoc" ] && [ "${STATSBAR_ALLOW_ADHOC_DMG:-0}" != "1" ]; then
    echo "❌ $APP.app is ad-hoc signed — refusing to package a release DMG." >&2
    echo "   The identity is the TCC designated requirement, so this would reset Location and" >&2
    echo "   Bluetooth permissions for every user on v2.11.1 or later, each of whom would have to" >&2
    echo "   grant them again by hand." >&2
    echo "   Fix: create the 'StatsBar Local' certificate (see build_app.sh's signing header), or set" >&2
    echo "   STATSBAR_SIGN_IDENTITY to one that exists. To ship ad-hoc anyway, knowing the above:" >&2
    echo "   STATSBAR_ALLOW_ADHOC_DMG=1 ./build_dmg.sh" >&2
    exit 1
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
