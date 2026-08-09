# cocobat + StatsBar — a homemade coconutBattery

A menu-bar hardware inspector for macOS, plus the CLI script it grew out of. Battery health comes from the
IOKit registry `AppleSmartBattery` — the same data source coconutBattery uses — and no part of it needs root.

Not notarized, so macOS quarantines the first launch. Clear it on whatever copy you installed:

```bash
xattr -dr com.apple.quarantine /Applications/StatsBar.app
```

Or approve it once through the UI: right-click ▸ Open ▸ Open. On macOS 15 and later that confirmation
moved to **System Settings ▸ Privacy & Security ▸ "Open Anyway"** after the first blocked launch.

## Files

| File | What it is | Requirements |
|---|---|---|
| `cocobat.py` | CLI script — run immediately | macOS + python3 (preinstalled) |
| `Sources/` | SwiftUI menu bar app (split by layer: Core / Model / Reader / Support / View / App) | macOS 13+, Xcode CLT |
| `build_app.sh` | Compiles + packages + signs the `.app` | same as above |
| `run_tests.sh` + `Tests/` | Unit tests for the pure layer — see [Development](#3-development) | same as above |
| `build_dmg.sh` | Gates on the tests, then packages `StatsBar-v<version>.dmg` | same as above |
| `update_appcast.sh` | Signs a released DMG into `appcast.xml` so Sparkle clients see it | a Sparkle EdDSA key in the keychain |

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
./build_app.sh            # builds, signs and relaunches StatsBar.app
```

There is deliberately no shorter `swiftc` one-liner to run it unbundled. Sparkle is linked in, so the
compile needs `-F Frameworks -framework Sparkle` and an rpath to resolve it at launch; and an unbundled
binary has no `Info.plist`, which is where the icon, `SUFeedURL`/`SUPublicEDKey` and the Location and
Bluetooth usage strings live — so it gets no icon, no auto-update, no Wi-Fi network name and no accessory
battery levels. Notifications go too, for a different reason: without a bundle identifier there is nothing
for `UNUserNotificationCenter` to post as, so alerts fall back to the self-drawn HUD. `build_app.sh` is the
only path that produces something that actually works. To check a change compiles without packaging it, use
the typecheck command under [Development](#3-development).

### What it shows

One always-visible **StatsBar** item is the hub: an at-a-glance row per metric, switches to show or hide the
other items, and Launch at login. It can't be hidden, because it's where you turn the rest back on. (Launch
at login also works the long way round: **System Settings → General → Login Items**.)

Five further menu-bar items are optional, each with its own popover:

- **Battery** — charge, macOS's own Maximum Capacity, cycle count against the pack's rated life,
  temperature, voltage, live charge/discharge power off the SMC power rails, and time remaining. Live fan
  speeds are pinned above it, each shown against its own floor and ceiling rather than as a bare RPM.
- **CPU** — per-logical-core usage with that core's die temperature, frequency, thermal pressure, Low Power
  Mode, load average divided by core count, and the top processes (right-click one to quit it).
- **Memory** — App / Wired / Compressed / Cached Files / Free, with the same per-process list.
- **Network** — interface, addresses, DNS resolvers, Wi-Fi name and signal, public IP with country flag,
  live throughput and session totals.
- **Bluetooth** — connected accessories and their battery levels, including BLE devices that
  `system_profiler` does not report.

**Attached displays** are listed in the StatsBar hub rather than getting an item of their own — they're
event-driven, so there is nothing to poll: name, the resolution System Settings shows, the panel's real
pixel grid beneath it, refresh rate and diagonal. **iPhone / iPad and Android** batteries appear in the
Battery popover, with an optional alert when an iPhone or iPad battery gets hot
(Android exposes no temperature to alert on).

Values are selectable and right-clickable for Copy — serial numbers, MAC and IP addresses and DNS resolvers
are the things you open an inspector in order to paste somewhere else.

### Permissions it will ask for

Three prompts, all optional in the sense that only the matching row goes blank if you decline:

| Prompt | Why | What breaks without it |
|---|---|---|
| Location | macOS 14+ only reveals the Wi-Fi network name (SSID) to apps holding Location authorization | Wi-Fi name |
| Bluetooth | per-device battery levels for accessories `system_profiler` omits, read over GATT | some accessory batteries |
| Notifications | the hot-iPhone alert | a self-drawn HUD is used instead |

`build_app.sh` signs with a stable self-signed identity when one exists, because macOS ties those grants to
the code-signing identity — an ad-hoc signature changes every build and re-prompts every time. The header of
that script explains how to create the certificate.

### Phones

iPhone/iPad is auto-detected over **USB or Wi-Fi** (the "📱 iPhone / iPad (USB / Wi-Fi)" section), using the
same `libimobiledevice` mechanism as the CLI. Android is read over USB with `adb`.

```bash
brew install libimobiledevice     # iPhone / iPad
brew install --cask android-platform-tools   # Android (adb)
# Plug in the cable → unlock the device → tap Trust (iOS) or enable USB debugging (Android)
```

If the relevant tool isn't installed, the section shows install instructions rather than an error.

### Updates

The app checks a Sparkle appcast every 6 hours and offers updates in-app. Each release is EdDSA-signed and
verified against a public key baked into the bundle, so a download that doesn't verify is refused.

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
`run_tests.sh` greps it against a denylist — the frameworks that imply I/O, plus a bare `ObservableObject`
conformance, which is not an import at all — and fails the run on a match. The rest of `Sources/` is
excluded deliberately: a reader's output is whatever this Mac's sensors happen to say that second, so
asserting on it would test the hardware, and the views need a running `NSApplication`.

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

Today that is roughly one line in eight — about 1,150 of the 9,100 under `Sources/` — so a green suite is a
statement about the arithmetic and nothing else. For anything touching a reader or a view, compile the
whole tree the way CI does:

```bash
swiftc -parse-as-library -target "$(uname -m)-apple-macos13" -typecheck $(find Sources -name '*.swift') -F Frameworks
```

## Data shown by `cocobat.py`

The CLI leads with the raw IOKit ratios. The app leads with macOS's own calibrated State of Charge and
Maximum Capacity instead — the raw mAh ratio reads a few percent low even on a full battery — and keeps the
raw figures as the secondary line under each bar. Both are correct answers to different questions, so the
headline numbers will not match the CLI's exactly.

- **Current charge**: `AppleRawCurrentCapacity` / `AppleRawMaxCapacity` (mAh)
- **Health %** = Full charge capacity ÷ `DesignCapacity` — the same formula coconutBattery uses
  - 🟢 ≥ 80% · 🟡 60–79% · 🔴 < 60%
- **Cycle count, temperature, voltage, charge/discharge power, adapter wattage, time remaining**

## Notes

- Cross-check against raw ioreg: `ioreg -rn AppleSmartBattery`
- Battery manufacture date is only available on Intel Macs (Apple Silicon doesn't expose this key)
- Newer iOS versions may block some health keys over diagnostics — the script will report if they're missing
- Want to add Plus features (SQLite history, below-threshold notifications)? The foundation is already there, just wire it up
