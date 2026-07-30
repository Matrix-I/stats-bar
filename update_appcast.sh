#!/bin/bash
# update_appcast.sh — add a released DMG to appcast.xml so Sparkle clients can find it.
#
#   ./update_appcast.sh <dmg-path> [release-notes.md|.html]
#   e.g. ./update_appcast.sh StatsBar-v2.12.1.dmg RELEASE_NOTES_v2.12.1.md
#
# It EdDSA-signs the DMG with the private key in this machine's keychain (see .sparkle-tools/sign_update
# and the key pair from generate_keys), then prepends an <item> to appcast.xml pointing at the DMG's
# GitHub release asset URL. Commit + push appcast.xml afterwards — SUFeedURL serves it raw from GitHub,
# so the new version goes live to every installed copy the moment main updates.
#
# Run this AFTER the GitHub release + asset upload exist: the enclosure URL is checked against the live
# asset before anything is written, so running it early fails loudly instead of publishing a 404.
#
# The version is no longer an argument — it is read out of the DMG's own bundle. appcast.xml is the one
# artifact on the release path that reaches every installed copy with nothing in front of it: CI never
# reads it, no tag covers the commit that adds an item, and Sparkle compares the number written here
# against the number in the shipped bundle. A typo used to be publishable, and its failure shape is an
# update that installs successfully and is then offered again forever.
#
# Every check below runs BEFORE the file is touched, so a rejected release leaves appcast.xml untouched
# rather than half-written.

set -euo pipefail
cd "$(dirname "$0")"

DMG="${1:?usage: update_appcast.sh <dmg-path> [notes-file]}"
NOTES_FILE="${2:-}"
REPO="Matrix-I/stats-bar"
APPCAST="appcast.xml"

fail() { echo "❌ $1" >&2; exit 1; }

[ -f "$DMG" ] || fail "DMG not found: $DMG  (the version argument is gone — pass only the DMG path)"
[ -x ".sparkle-tools/sign_update" ] || fail ".sparkle-tools/sign_update missing — run ./fetch_sparkle.sh"
[ -x ".sparkle-tools/generate_keys" ] || fail ".sparkle-tools/generate_keys missing — run ./fetch_sparkle.sh"
# Checked here rather than at the point of use: down there a missing xmllint is indistinguishable from
# malformed XML, so the script would reject a perfectly good splice and blame the file for it.
command -v xmllint >/dev/null || fail "xmllint not found — it is what proves the spliced feed still parses"

# The notes file is validated up front too, rather than beside the code that embeds it further down. Every
# one of these is knowable before the DMG is mounted, so failing here costs the operator nothing — whereas
# checking later means a keychain signature and a network round trip are spent before the rejection.
if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || fail "notes file not found: $NOTES_FILE"
    # A stray ]]> closes the CDATA early and yields an appcast Sparkle cannot parse. That breaks more than
    # this release: a feed that fails to parse hides EVERY item, so no client sees this update or any later
    # fix until main is corrected — and it fails silently, with nothing shown to the user.
    if grep -qF ']]>' "$NOTES_FILE"; then
        fail "$NOTES_FILE contains ']]>', which would close the CDATA block early"
    fi
    # An XML document declares itself UTF-8, so a stray byte from another encoding cannot go in it.
    iconv -f UTF-8 -t UTF-8 "$NOTES_FILE" >/dev/null 2>&1 \
        || fail "$NOTES_FILE is not valid UTF-8 — the feed declares UTF-8 and cannot carry it"
fi

# ── 1. Everything the item says, read out of the artifact being published ─────────────────────────────
# Mounted read-only: the bundle inside the DMG is what users install, so it is the only copy whose version
# means anything here. Reading StatsBar.app from the working tree would answer a different question — what
# is built right now, not what is being published.
MOUNT="$(mktemp -d)"
cleanup() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT
# `|| fail`, because -quiet suppresses hdiutil's own diagnostic and set -e would then abort with no output
# at all. The likeliest trigger is not a corrupt image but an operator who double-clicked the DMG in Finder
# to look at it before publishing: it is already attached, the second attach fails, and the script would
# die silently one line into its work.
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly -quiet \
    || fail "could not mount $DMG — already attached (check Finder / hdiutil info), or not a complete image?"
# hdiutil create -srcfolder puts the staged folder's CONTENTS at the volume root, so the bundle sits
# beside the /Applications symlink rather than one level down.
APP_PLIST="$MOUNT/StatsBar.app/Contents/Info.plist"
[ -f "$APP_PLIST" ] || fail "no StatsBar.app at the root of $DMG"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PLIST" 2>/dev/null || true; }
VERSION="$(plist CFBundleShortVersionString)"
BUNDLE_VERSION="$(plist CFBundleVersion)"
MIN_OS="$(plist LSMinimumSystemVersion)"
PUB_SHIPPED="$(plist SUPublicEDKey)"
cleanup
trap - EXIT

[ -n "$VERSION" ] || fail "the packaged bundle declares no CFBundleShortVersionString"

# A snapshot is a development build. Publishing one hands every user a version string the real release
# will later reuse, so Sparkle compares them equal and never offers that release at all.
case "$VERSION" in
    *-SNAPSHOT) fail "$DMG is a SNAPSHOT build ($VERSION) — drop the suffix in build_app.sh and rebuild" ;;
esac

# Sparkle compares CFBundleVersion, not the marketing string. These two agreeing is what makes the item's
# <sparkle:version> mean what the rest of the file claims it means.
[ "$BUNDLE_VERSION" = "$VERSION" ] \
    || fail "packaged CFBundleVersion ($BUNDLE_VERSION) != CFBundleShortVersionString ($VERSION)"

# minimumSystemVersion used to be a bare literal in this file, a third copy two files away from the one
# the app declares. Taking it from the bundle means the feed cannot advertise a floor the binary does not
# have — whose failure shape is the worst available: a client below the real floor passes Sparkle's own
# check, downloads, and gets a binary the loader then refuses.
[ -n "$MIN_OS" ] || fail "the packaged bundle declares no LSMinimumSystemVersion"

# Publishing one version twice leaves two items Sparkle would choose between arbitrarily.
if grep -q "<sparkle:version>$VERSION</sparkle:version>" "$APPCAST"; then
    fail "$APPCAST already has an item for $VERSION"
fi

# ── 2. Sign, with the strongest key check the signing source allows ───────────────────────────────────
# sign_update prints e.g.  sparkle:edSignature="BASE64==" length="1246073"
# By default the private key is read from this machine's keychain — the FIRST run shows a one-time
# macOS prompt ("sign_update wants to use a key…"); click "Always Allow" and later runs are silent.
# For non-interactive/CI use, export the key once (`.sparkle-tools/generate_keys -x KEYFILE`, keep it
# out of the repo) and point SPARKLE_ED_KEY_FILE at it to skip the keychain entirely.
#
# The key check has to live INSIDE this branch, not above it. sign_update --verify derives the public key
# from whatever private key it signed with, so it can only prove the signature matches the file — never
# that the shipped app can check it. The app checks against the SUPublicEDKey baked into its Info.plist,
# so that is what the signing key has to match, and `generate_keys -p` can only answer for the keychain.
# Running that comparison unconditionally would have broken the exported-key path this same comment
# advertises — on a machine with no keychain key it dies on a gate that is not the operator's problem —
# and on a machine with both it would have validated a key that did not sign anything.
[ -n "$PUB_SHIPPED" ] || fail "the packaged bundle declares no SUPublicEDKey"
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ] && [ -f "$SPARKLE_ED_KEY_FILE" ]; then
    echo "🔑 signing from SPARKLE_ED_KEY_FILE — the SUPublicEDKey cross-check is not possible from an"
    echo "   exported key file, so this path trades the strongest gate for non-interactive signing."
    SIG_ATTRS="$(.sparkle-tools/sign_update --ed-key-file "$SPARKLE_ED_KEY_FILE" "$DMG")"
    VERIFY_KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
    PUB_KEYCHAIN="$(.sparkle-tools/generate_keys -p 2>/dev/null)" \
        || fail "could not read the public key from the keychain — is one generated? (generate_keys -p)"
    PUB_KEYCHAIN="$(printf '%s' "$PUB_KEYCHAIN" | tr -d '[:space:]')"
    [ "$PUB_KEYCHAIN" = "$PUB_SHIPPED" ] \
        || fail "keychain public key ($PUB_KEYCHAIN) != SUPublicEDKey in the packaged app ($PUB_SHIPPED)"
    SIG_ATTRS="$(.sparkle-tools/sign_update "$DMG")"
    VERIFY_KEY_ARGS=()
fi
echo "🔏 $SIG_ATTRS"

SIGNATURE="$(printf '%s' "$SIG_ATTRS" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s' "$SIG_ATTRS" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] && [ -n "$LENGTH" ] || fail "could not parse sign_update output: $SIG_ATTRS"

# ${ARR[@]+"${ARR[@]}"} rather than "${ARR[@]}": /bin/bash here is 3.2, where expanding an EMPTY array
# under `set -u` is an unbound-variable error — the same trap 85fe83d fixed in run_tests.sh.
.sparkle-tools/sign_update --verify "$DMG" "$SIGNATURE" \
    ${VERIFY_KEY_ARGS[@]+"${VERIFY_KEY_ARGS[@]}"} >/dev/null \
    || fail "the signature just produced does not verify against $DMG"

LOCAL_SIZE="$(wc -c < "$DMG" | tr -d '[:space:]')"
[ "$LENGTH" = "$LOCAL_SIZE" ] || fail "sign_update reported length $LENGTH but $DMG is $LOCAL_SIZE bytes"

# ── 4. The enclosure URL, checked against the live asset ──────────────────────────────────────────────
# The signature covers the file's bytes, not its name, so a URL pointing at a missing or different asset
# is valid-looking and fails only on other people's machines. One curl settles both questions. The LAST
# content-length in the header dump is the one that counts: -L follows GitHub's redirect to a signed asset
# host, and the redirect response carries a length of its own.
#
# The header stream is lower-cased before matching rather than matched case-insensitively, because the awk
# macOS ships (one-true-awk, version 20200816) silently ignores IGNORECASE — a header block written
# "Content-Length:" then matches nothing at all. GitHub currently answers over HTTP/2, whose header names
# are lower case by protocol, so the naive version passed every test here and would have failed the first
# time a redirect or proxy answered in HTTP/1.1 — refusing a release whose asset was perfectly fine.
URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
echo "🌐 Checking the published asset at $URL ..."
# Capturing the bytes and judging the status are separate statements on purpose. As one command
# substitution around a pipeline, pipefail turns curl's non-zero exit into the assignment's exit and set -e
# kills the script THERE — so the message below could never print, and the script's own documented primary
# failure (running this before the asset is uploaded) came out as a bare non-zero exit with no explanation.
HEADERS="$(curl -sfIL "$URL" 2>/dev/null)" \
    || fail "$URL did not resolve — create the release and upload the asset, then re-run"
# n is reset at each new status line so a redirect's length is never mistaken for the final response's, and
# the value is taken after the colon rather than as whitespace-field 2, so a space-less header still parses.
REMOTE_SIZE="$(printf '%s\n' "$HEADERS" | tr 'A-Z' 'a-z' | awk '
    /^http\// { n = "" }
    /^content-length:/ { sub(/^content-length:[[:space:]]*/, ""); gsub(/[[:space:]\r]/, ""); n = $0 }
    END { print n }')"
[ -n "$REMOTE_SIZE" ] || fail "$URL resolved but reported no content-length — cannot compare it to the DMG"
[ "$REMOTE_SIZE" = "$LOCAL_SIZE" ] \
    || fail "the asset there is $REMOTE_SIZE bytes but the signed DMG is $LOCAL_SIZE — a different file"

# ── 5. Release notes ──────────────────────────────────────────────────────────────────────────────────
# A notes link is emitted ALWAYS, and that is a fix rather than a detail. UpdateUserDriver shows its
# Changelog button only when the item carries one of releaseNotesLink / fullReleaseNotesLink / <link>, and
# deliberately renders nothing in-window — it opens the URL in a browser instead. This script used to emit
# the link ONLY when no notes file was given, so passing carefully written notes was exactly what hid
# them: every release from 2.6.0 to 2.12.0 put its notes in <description>, where no user could reach them.
#
# fullReleaseNotesLink, NOT releaseNotesLink, and the difference is not cosmetic. Sparkle DOWNLOADS a
# releaseNotesLink at update-found and runs the bytes through the same signature verifier the archive uses;
# a bundle carrying SUPublicEDKey rejects anything unsigned, and a GitHub-rendered page cannot be signed —
# so that element buys a discarded fetch and a permanent "improperly signed" error in Console on every
# check, for a button that never depended on the fetch. fullReleaseNotesLink is the element Sparkle
# documents as the one opened "in the user's web browser" (SPUStandardUserDriverDelegate.h), it is not
# fetched, and UpdateUserDriver's fallback chain picks it up identically. <description> stays as the
# in-window source, which is what SUAppcastItem.h calls the alternative to a releaseNotesURL.
NOTES_LINK="<sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>"
if [ -n "$NOTES_FILE" ]; then
    DESC="$NOTES_LINK
      <description><![CDATA[$(cat "$NOTES_FILE")]]></description>"
else
    DESC="$NOTES_LINK"
fi

# LC_ALL=C: pubDate is an RFC 822 date, whose day and month names are English by specification. Without it
# the operator's locale decides, and a machine set to Vietnamese would write "Th 5, 30 Th7 2026" into a
# field every Sparkle client parses.
PUBDATE="$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")"

ITEM=$(cat <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUNDLE_VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      $DESC
      <enclosure url="$URL" $SIG_ATTRS type="application/octet-stream" />
    </item>
EOF
)

# ── 6. Splice into a new file, prove it parses, and only then move it into place ───────────────────────
# Insert the item right after the APPCAST_ITEMS marker (newest first). A Python splice keeps the rest of the
# XML byte-for-byte intact — no reformatting, no dependency beyond the system python3.
#
# It writes a SEPARATE file, and $APPCAST is replaced only once xmllint has passed on that file. The
# earlier shape — splice in place, then roll back from a .bak if the result was malformed — had a hole
# exactly where it mattered: `open(path, "w")` truncates before it encodes anything, so an exception during
# the write (a notes file carrying a byte that is not valid UTF-8 is enough) left $APPCAST truncated, and
# because python then exited non-zero, set -e killed the script BEFORE the rollback could run. The operator
# was left with a truncated feed in the working tree and the next documented step being "commit and push".
# Writing beside the live file cannot fail that way: if anything goes wrong, $APPCAST was never opened.
NEW="$APPCAST.new"
trap 'rm -f "$NEW"' EXIT
MARKER="APPCAST_ITEMS:" ITEM="$ITEM" python3 - "$PWD/$APPCAST" "$PWD/$NEW" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
marker, item = os.environ["MARKER"], os.environ["ITEM"]
with open(src, encoding="utf-8") as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    if marker in line:
        lines.insert(i + 1, item + "\n")
        break
else:
    sys.exit(f"marker {marker!r} not found in {src}")
with open(dst, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY

# The feed is served raw to every installed copy, so a malformed item is a silent outage for all of them —
# a feed that does not parse hides every version, not just this one. xmllint's own diagnostic is kept
# rather than discarded: it names the line, and "not well-formed" with no detail is not actionable.
xmllint --noout "$NEW" || fail "the spliced feed is not well-formed XML — $APPCAST was not touched"
mv "$NEW" "$APPCAST"
trap - EXIT

echo "✅ $APPCAST updated for v$VERSION"
echo "   sparkle:version $BUNDLE_VERSION · minimumSystemVersion $MIN_OS · $LOCAL_SIZE bytes · notes link included"
echo "   Next: commit $APPCAST and push main so the feed goes live."
