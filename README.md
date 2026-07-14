# cocobat + BatteryBar — a homemade coconutBattery

```bash
cd ~/Applications && xattr -dr com.apple.quarantine BatteryBar.app
```

Reads battery health from the IOKit registry `AppleSmartBattery` — the same data source coconutBattery uses. No root required.

## Files

| File | What it is | Requirements |
|---|---|---|
| `cocobat.py` | CLI script — run immediately | macOS + python3 (preinstalled) |
| `BatteryBar.swift` | SwiftUI menu bar app | macOS 13+, Xcode CLT |
| `build_app.sh` | Compiles + packages the `.app` | same as above |

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
./build_app.sh            # builds BatteryBar.app
open BatteryBar.app
```

Or run it quickly without bundling:

```bash
swiftc -O BatteryBar.swift -o BatteryBar && ./BatteryBar
```

Launch at login: **System Settings → General → Login Items** → add `BatteryBar.app`.

The app now also auto-detects an iPhone/iPad plugged in over USB (the "📱 iPhone / iPad (USB)" section in the menu), using the same `libimobiledevice` mechanism as the CLI:

```bash
brew install libimobiledevice
# Plug in the cable → unlock the device → tap Trust → reopen the menu or click "Refresh"
```

If `libimobiledevice` isn't installed, this section shows install instructions instead of an error.

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
# battery-bar
