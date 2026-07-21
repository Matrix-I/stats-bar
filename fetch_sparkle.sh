#!/bin/bash
# fetch_sparkle.sh — downloads the pinned Sparkle release and vendors it into the repo:
#   Frameworks/Sparkle.framework   — embedded into StatsBar.app and linked at build time
#   .sparkle-tools/                — generate_keys / sign_update / generate_appcast (release-time)
#
# Both paths are .gitignored: the ~15 MB framework/tools are reproducibly re-fetched here instead of
# committed. build_app.sh calls this so a fresh checkout builds without any manual setup. Idempotent —
# it no-ops when the framework is already present, so normal rebuilds don't hit the network.

set -euo pipefail
cd "$(dirname "$0")"

SPARKLE_VERSION="2.9.4"
FRAMEWORK="Frameworks/Sparkle.framework"

if [ -d "$FRAMEWORK" ] && [ -x ".sparkle-tools/sign_update" ]; then
    exit 0   # already vendored
fi

echo "⬇️  Fetching Sparkle $SPARKLE_VERSION (one-time; ~15 MB) ..."
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/sparkle.tar.xz" "$URL"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP"

mkdir -p Frameworks .sparkle-tools
rm -rf "$FRAMEWORK"
cp -R "$TMP/Sparkle.framework" "$FRAMEWORK"
cp "$TMP/bin/generate_keys" "$TMP/bin/sign_update" "$TMP/bin/generate_appcast" .sparkle-tools/

echo "✅ Sparkle $SPARKLE_VERSION vendored into $FRAMEWORK and .sparkle-tools/"
