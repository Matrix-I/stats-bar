#!/bin/bash
# run_tests.sh — runs the unit tests (Sources/Core via Package.swift). Use this rather than a bare
# `swift test`: on a machine with only the Command Line Tools installed, a bare `swift test` cannot
# find swift-testing and fails to build. Extra arguments are passed straight through, so
# `./run_tests.sh --filter Formatting` works.
#
# Requires: Xcode Command Line Tools — the same and only requirement build_app.sh has.

set -euo pipefail
cd "$(dirname "$0")"

# --- The pure-layer guard -------------------------------------------------------------------------
#
# Sources/Core is the only directory the test target compiles, and it is testable precisely because
# nothing in it does I/O: no SMC, IOKit, Mach or sysctl reads, no subprocesses, no ObservableObject.
# That rule is what keeps `swift test` deterministic, so it is checked rather than just documented —
# otherwise the first hardware read to land in Core makes some test machine-dependent, and it fails
# for whoever runs it next on a cooler Mac.
#
# A denylist of imports, not a proof: it catches the realistic mistake (moving a reader in, or
# reaching for AppKit for one convenience) and says nothing about cleverer ways to smuggle in state.
FORBIDDEN='^import (AppKit|IOKit|Combine|CoreBluetooth|CoreWLAN|UserNotifications|SystemConfiguration|Network)\b|ObservableObject'
if violations=$(grep -REn "$FORBIDDEN" Sources/Core 2>/dev/null); then
    echo "❌ Sources/Core is the pure layer — it must not do I/O or hold live objects."
    echo "   Move this code to Sources/Reader or Sources/Support and keep the arithmetic in Core:"
    echo "$violations" | sed 's/^/   /'
    exit 1
fi

# --- swift-testing on a Command-Line-Tools-only machine -------------------------------------------
#
# SwiftPM can't find swift-testing when the active developer directory is the CLT rather than a full
# Xcode: it derives the framework path from an Xcode-relative layout and lands on nonsense (it passes
# a literal /Library/Developer/Developer/usr/... plugin path, and no -F at all). The framework and its
# interop dylib ARE both shipped in the CLT, just one directory away from where dyld is told to look —
# Testing.framework's own @rpath reference to lib_TestingInterop.dylib is off by one level — so the
# fix is to name both locations explicitly.
#
# Only added when those directories actually exist, which is what makes this a no-op on a machine
# with full Xcode: there SwiftPM's own wiring works and nothing needs overriding. That no-op path is
# the reason line 56 expands FLAGS the long way round — see the note there.
DEV="$(xcode-select -p)"
FRAMEWORKS="$DEV/Library/Developer/Frameworks"
INTEROP="$DEV/Library/Developer/usr/lib"
FLAGS=()
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
    FLAGS+=(-Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS")
    [ -d "$INTEROP" ] && FLAGS+=(-Xlinker -rpath -Xlinker "$INTEROP")
fi

# Expect one linker warning: Testing.framework is built for macOS 14 while this package declares 13.0.
# That is deliberate and must not be "fixed" by raising the platform — 13.0 is what makes availability
# checking in Sources/Core match the app that build_app.sh actually ships. The test bundle isn't
# shipped, so linking it against a newer dylib costs nothing.
echo "🧪 Running unit tests (Sources/Core) ..."
# ${FLAGS[@]+"${FLAGS[@]}"}, not "${FLAGS[@]}": /bin/bash on macOS is 3.2, where expanding an EMPTY
# array under `set -u` is an "unbound variable" error rather than expanding to nothing. FLAGS is empty
# on exactly the machine the block above is written for — one with full Xcode, where none of the
# overrides are needed — so the plain form killed the script before `swift test` ran, and killed it
# with a shell error that says nothing about tests. `"$@"` needs no such guard: bash special-cases it.
exec swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
