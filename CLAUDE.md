# StatsBar — notes for working in this repo

## Build and test

```bash
./build_app.sh              # compile + bundle + sign + relaunch StatsBar.app
./build_app.sh --no-launch  # same, without relaunching (what CI runs)
./run_tests.sh              # unit tests — use this, NOT a bare `swift test`
```

There is no Xcode project and no SwiftPM app target. `build_app.sh` runs `swiftc -O` over every `.swift`
file under `Sources/` as a single module and links Sparkle. Only the Command Line Tools are needed; a full
Xcode install is not. `run_tests.sh` exists because SwiftPM cannot locate swift-testing under the CLT by
itself — its header explains the three flags. `Package.swift` is for tests only and `build_app.sh` never
reads it.

Tests use swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest — the CLT ships the
former and not the latter.

## Where new code goes

`Sources/` is split by layer: `Core` `Model` `Reader` `Support` `View` `App`.

**`Sources/Core` is the pure layer, and the only directory the tests compile.** No I/O and no live
objects: no SMC, IOKit, Mach or sysctl reads, no subprocesses, no `ObservableObject`. `run_tests.sh` greps
for violations and fails the run, so this is enforced rather than merely documented. SwiftUI value types
(`Color`) are fine.

New behaviour follows the memory path as its worked example:

1. `Reader/MemoryStats.swift` gathers the raw numbers (one `host_statistics64` call).
2. `Core/MemoryBuckets.swift` does the arithmetic on them — page counts in, buckets and fractions out.
3. `Model/MemoryInfo.swift` holds that value and adds read-only forwards, so ~20 call sites keep reading
   `info.free` rather than `info.buckets.free`.
4. `Tests/StatsBarCoreTests/MemoryBucketsTests.swift` pins it.

Arithmetic left inside a reader or a view cannot be reached by any test. Both of this repo's shipped
memory bugs lived in code shaped that way, and both printed believable gigabytes — nothing but a test
catches that class of defect. A new file in `Sources/Core` needs no manifest edit: the target is the
directory, not a file list.

## Conventions

- **Comments explain why, not what**, and at length where the reason isn't recoverable from the code —
  several files open with a header arguing for their own existence, and tests state the failure they
  guard against. Match that density; don't strip it.
- **Commit subjects** are `type(scope): imperative summary`; bodies are prose paragraphs wrapped at 94
  columns. No bullet lists or ASCII tables in commit bodies.
- **The app version lives only in `build_app.sh`** — bump both `CFBundleShortVersionString` and
  `CFBundleVersion`. Between releases the short version carries a `-SNAPSHOT` suffix; `CFBundleVersion`
  stays a plain numeric triple, because Sparkle compares that key against the appcast. Everything
  downstream now *derives* from those two lines rather than restating them: `build_dmg.sh` reads the
  bundle to name `StatsBar-v<version>.dmg`, and `update_appcast.sh` reads the DMG to fill in the appcast
  item. Don't reintroduce a second place to type a version.
- **Unsigned `-` traps in Swift; only `&-` wraps.** The app ships `-O`, not `-Ounchecked`, so those checks
  are in the release binary: guard any subtraction that could go negative, and don't describe the failure
  as "wrapping to a huge number" — it is a crash.
- **`Frameworks/` holds a signed Sparkle bundle.** It is gitignored and fetched by `fetch_sparkle.sh`.
  Don't `cd` into it (that breaks codesign paths) and don't commit it.

## Verifying a change

`./run_tests.sh` covers roughly one line in eight — about 1,150 of the 9,100 under `Sources/` — so a green
suite says something about the arithmetic and nothing about the remaining 92%. Deliberately approximate:
the exact pair written here before ("541 of 8,139") was falsified two commits later by a new file in
`Sources/Core`, and shipped that way. Recount rather than trust it:

```bash
find Sources/Core -name '*.swift' -exec cat {} + | wc -l   # and the same over Sources/
```

For anything touching a reader, a view or the app shell, also compile the whole tree the way CI's build
job does:

```bash
swiftc -parse-as-library -target "$(uname -m)-apple-macos13" -typecheck $(find Sources -name '*.swift') -F Frameworks
```

When a change is *meant* to preserve behaviour, prove it rather than asserting it: copy the previous
implementation out of git into a throwaway file and run both against the same inputs — live readings for
the hardware paths, generated sequences for the stateful ones. That is how the `Sources/Core` extraction
was checked, and it is a different claim from "the tests still pass".

Two guards deserve a mutant before you trust a test of them: change the code so the guard no longer fires
and confirm the suite goes red. A guard tested only with inputs a weaker guard would also reject is not
tested.

## Cutting a release

`appcast.xml` is the one artifact that reaches every installed copy with nothing in front of it — CI never
reads it, no tag covers the commit that adds an item, and `SUFeedURL` serves it raw from `main`. So the
checks live in the scripts rather than in whoever is running them, and the order below is the order they
expect:

1. Set both version keys in `build_app.sh` to the release number and commit that on its own. Only the
   short version ever carries the `-SNAPSHOT` suffix, so that is the only one losing anything.
2. `./build_dmg.sh` — gates on a non-zero passing test count, verifies the signature, and writes
   `StatsBar-v<version>.dmg`. There is no `mv` step any more; the name comes from the bundle.
3. Push `main` **before** creating the release: `gh release create` puts the tag on `origin/main`'s head.
4. `gh auth switch --user Matrix-I` (only that account can write), then `gh release create v<version>
   StatsBar-v<version>.dmg --title "v<version>" --notes-file <notes>.md`, then switch back. The notes body
   is not optional any more: the appcast item now carries a Changelog link to exactly that page, so a
   release published without one gives every user a button that opens an empty release.
5. `./update_appcast.sh StatsBar-v<version>.dmg <notes>.md` — takes no version argument; it mounts the DMG
   and reads it. It refuses a SNAPSHOT, a duplicate version, a keychain key the bundle won't accept, a
   `]]>` in the notes, and an enclosure URL whose size doesn't match the signed file. The splice is written
   beside `appcast.xml` and only moved into place once `xmllint` passes, so a rejected release leaves the
   live feed untouched rather than half-written.
6. Commit `appcast.xml`, push, then reopen the next `-SNAPSHOT` in a following commit.

**Keep signing with the stable identity.** Read off the shipped DMGs: v2.9.0, v2.9.1, v2.10.0 and v2.11.0
are `Signature=adhoc`; **v2.11.1 and v2.12.0 are `Authority=StatsBar Local`**. So the switch happened at
v2.11.1 and nobody recorded it. The identity *is* the TCC designated requirement, so reverting to ad-hoc
would reset Location and Bluetooth grants for everyone on either of those two releases. Which identity you
get is decided by whatever `security find-identity -p codesigning` matches for
`${STATSBAR_SIGN_IDENTITY:-StatsBar Local}` at build time — nothing in the repo pins it, which is why it
moved unnoticed, helped along by `build_dmg.sh` asserting "ad-hoc signed" unconditionally. It now reports
what it actually used.

**The version number is a judgement call, not a formula.** `-SNAPSHOT` names the next *planned* release, not
a commitment: `ee29c9a` dropped `2.12.0-SNAPSHOT` straight to `2.11.1` when the content turned out to be
fixes, and reopened the snapshot afterwards. Fixes-only ranges should do the same.
