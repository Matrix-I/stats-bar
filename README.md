# cocobat + StatsBar — a homemade coconutBattery

```bash
cd ~/Applications && xattr -dr com.apple.quarantine StatsBar.app
```

Reads battery health from the IOKit registry `AppleSmartBattery` — the same data source coconutBattery uses. No root required.

## Files

| File | What it is | Requirements |
|---|---|---|
| `cocobat.py` | CLI script — run immediately | macOS + python3 (preinstalled) |
| `Sources/` | SwiftUI menu bar app (split by layer: Core / Model / Reader / Support / View / App) | macOS 13+, Xcode CLT |
| `build_app.sh` | Compiles + packages the `.app` | same as above |
| `run_tests.sh` + `Tests/` | Unit tests for the pure layer — see [Development](#3-development) | same as above |

## 1. CLI — run immediately

```bash
chmod +x cocobat.py
./cocobat.py              # Mac battery info
./cocobat.py --watch 5    # live refresh every 5s
./cocobat.py --json       # JSON output for other scripts
./cocobat.py --ios        # read iPhone/iPad over USB
```

Reading iPhone/iPad also requires:

```bash
brew install libimobiledevice
# Plug in the cable → unlock the device → tap Trust → run again
```

## 2. Menu bar app

```bash
chmod +x build_app.sh
./build_app.sh            # builds StatsBar.app
open StatsBar.app
```

Or run it quickly without bundling:

```bash
swiftc -O -parse-as-library $(find Sources -name '*.swift') -o StatsBar && ./StatsBar
```

Launch at login: **System Settings → General → Login Items** → add `StatsBar.app`.

The app now also auto-detects an iPhone/iPad plugged in over USB (the "📱 iPhone / iPad (USB)" section in the menu), using the same `libimobiledevice` mechanism as the CLI:

```bash
brew install libimobiledevice
# Plug in the cable → unlock the device → tap Trust → reopen the menu or click "Refresh"
```

If `libimobiledevice` isn't installed, this section shows install instructions instead of an error.

## 3. Development

```bash
./run_tests.sh                      # unit tests
./run_tests.sh --filter Formatting  # just one suite
```

Use `run_tests.sh`, not a bare `swift test`: with only the Command Line Tools installed, SwiftPM cannot
find swift-testing on its own and the build fails. The script points it at the right place, and is a no-op
wherever SwiftPM's own wiring already works. `Package.swift` exists solely to run these tests — it does not
build the app, and `build_app.sh` never reads it.

**`Sources/Core` is the pure layer**: no I/O and no live objects — nothing that reads the SMC, IOKit, Mach
or sysctl, spawns a process, or is an `ObservableObject`. It is the only directory the tests compile, and
`run_tests.sh` fails the run if that rule is broken. The rest of `Sources/` is excluded deliberately: a
reader's output is whatever this Mac's sensors happen to say that second, so asserting on it would test the
hardware, and the views need a running `NSApplication`.

That makes the shape of a new feature four steps, with memory as the worked example to copy:

| Step | Example |
|---|---|
| A reader gathers the raw numbers | `Reader/MemoryStats.swift` — one `host_statistics64` call |
| A pure type in `Sources/Core` does the arithmetic | `Core/MemoryBuckets.swift` — page counts → App / Wired / Compressed / Cached / Free |
| The model holds it and forwards, so call sites don't change | `Model/MemoryInfo.swift` — `var buckets`, plus read-only `info.free` etc. |
| A test pins the arithmetic | `Tests/StatsBarCoreTests/MemoryBucketsTests.swift` |

Arithmetic left inside a reader or a view cannot be reached by a test, which is the whole reason for the
split — both of this repo's shipped memory bugs printed believable gigabytes and were invisible on screen.
A new pure file can go anywhere in `Sources/Core` with no manifest to update: the test target is the
directory, and `build_app.sh` finds every `.swift` under `Sources/` regardless.

Today that covers 541 of 8,139 lines, so a green suite is a statement about the arithmetic and nothing
else. For anything touching a reader or a view, compile the whole tree the way CI does:

```bash
swiftc -parse-as-library -target arm64-apple-macos13 -typecheck $(find Sources -name '*.swift') -F Frameworks
```

## Data shown

- **Current charge**: `AppleRawCurrentCapacity` / `AppleRawMaxCapacity` (mAh)
- **Health %** = Full charge capacity ÷ `DesignCapacity` — the same formula coconutBattery uses
  - 🟢 ≥ 80% · 🟡 60–79% · 🔴 < 60%
- **Cycle count, temperature, voltage, charge/discharge power, adapter wattage, time remaining**

## Notes

- Cross-check against raw ioreg: `ioreg -rn AppleSmartBattery`
- Battery manufacture date is only available on Intel Macs (Apple Silicon doesn't expose this key)
- Newer iOS versions may block some health keys over diagnostics — the script will report if they're missing
- Want to add Plus features (SQLite history, below-threshold notifications)? The foundation is already there, just wire it up
# stats-bar
