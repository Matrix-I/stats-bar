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
  stays a plain numeric triple, because Sparkle compares that key against the appcast.
- **Unsigned `-` traps in Swift; only `&-` wraps.** The app ships `-O`, not `-Ounchecked`, so those checks
  are in the release binary: guard any subtraction that could go negative, and don't describe the failure
  as "wrapping to a huge number" — it is a crash.
- **`Frameworks/` holds a signed Sparkle bundle.** It is gitignored and fetched by `fetch_sparkle.sh`.
  Don't `cd` into it (that breaks codesign paths) and don't commit it.

## Verifying a change

`./run_tests.sh` covers 541 of the 8,139 lines under `Sources/`, so a green suite says something about the
arithmetic and nothing about the other 94%. For anything touching a reader, a view or the app shell, also
compile the whole tree the way CI's build job does:

```bash
swiftc -parse-as-library -target arm64-apple-macos13 -typecheck $(find Sources -name '*.swift') -F Frameworks
```

When a change is *meant* to preserve behaviour, prove it rather than asserting it: copy the previous
implementation out of git into a throwaway file and run both against the same inputs — live readings for
the hardware paths, generated sequences for the stateful ones. That is how the `Sources/Core` extraction
was checked, and it is a different claim from "the tests still pass".

Two guards deserve a mutant before you trust a test of them: change the code so the guard no longer fires
and confirm the suite goes red. A guard tested only with inputs a weaker guard would also reject is not
tested.
