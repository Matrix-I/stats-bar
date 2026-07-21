#!/bin/bash
# update_appcast.sh — add a released DMG to appcast.xml so Sparkle clients can find it.
#
#   ./update_appcast.sh <version> <dmg-path> [release-notes.md|.html]
#   e.g. ./update_appcast.sh 2.3.0 StatsBar-v2.3.0.dmg RELEASE_NOTES_v2.3.0.md
#
# It EdDSA-signs the DMG with the private key in this machine's keychain (see .sparkle-tools/sign_update
# and the key pair from generate_keys), then prepends a <item> to appcast.xml pointing at the DMG's
# GitHub release asset URL. Commit + push appcast.xml afterwards — SUFeedURL serves it raw from GitHub,
# so the new version goes live to every installed copy the moment main updates.
#
# Run this AFTER the GitHub release + asset upload exist (the enclosure URL must resolve), then commit
# the updated appcast.xml. The DMG's Sparkle signature covers integrity; the URL just has to be right.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: update_appcast.sh <version> <dmg-path> [notes-file]}"
DMG="${2:?usage: update_appcast.sh <version> <dmg-path> [notes-file]}"
NOTES_FILE="${3:-}"
REPO="Matrix-I/stats-bar"

[ -f "$DMG" ] || { echo "❌ DMG not found: $DMG" >&2; exit 1; }
[ -x ".sparkle-tools/sign_update" ] || { echo "❌ .sparkle-tools/sign_update missing — run ./fetch_sparkle.sh" >&2; exit 1; }

# sign_update prints e.g.  sparkle:edSignature="BASE64==" length="1246073"
# By default the private key is read from this machine's keychain — the FIRST run shows a one-time
# macOS prompt ("sign_update wants to use a key…"); click "Always Allow" and later runs are silent.
# For non-interactive/CI use, export the key once (`.sparkle-tools/generate_keys -x KEYFILE`, keep it
# out of the repo) and point SPARKLE_ED_KEY_FILE at it to skip the keychain entirely.
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ] && [ -f "$SPARKLE_ED_KEY_FILE" ]; then
    SIG_ATTRS="$(.sparkle-tools/sign_update --ed-key-file "$SPARKLE_ED_KEY_FILE" "$DMG")"
else
    SIG_ATTRS="$(.sparkle-tools/sign_update "$DMG")"
fi
echo "🔏 $SIG_ATTRS"

URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
PUBDATE="$(date "+%a, %d %b %Y %H:%M:%S %z")"

# Release notes: embed an HTML file / a Markdown file's text as CDATA if given, else link to the release.
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    DESC="<description><![CDATA[$(cat "$NOTES_FILE")]]></description>"
else
    DESC="<sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
fi

ITEM=$(cat <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      $DESC
      <enclosure url="$URL" $SIG_ATTRS type="application/octet-stream" />
    </item>
EOF
)

# Insert the item right after the APPCAST_ITEMS marker (newest first). A Python splice keeps the rest
# of the XML byte-for-byte intact — no reformatting, no dependency beyond the system python3.
MARKER="APPCAST_ITEMS:" ITEM="$ITEM" python3 - "$PWD/appcast.xml" <<'PY'
import os, sys
path = sys.argv[1]
marker, item = os.environ["MARKER"], os.environ["ITEM"]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    if marker in line:
        lines.insert(i + 1, item + "\n")
        break
else:
    sys.exit(f"marker {marker!r} not found in {path}")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY

echo "✅ appcast.xml updated for v$VERSION"
echo "   Next: commit appcast.xml and push main so the feed goes live."
