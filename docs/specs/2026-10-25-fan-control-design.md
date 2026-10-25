# Fan control — design

Status: approved 2026-10-25. Not yet implemented.

## Goal

Let the user override the SMC's fan controller from the existing **🌀 Fans** section of the battery
popover, with three modes: **Auto**, **Max** and **Manual**. Today that section only reads the fans
(`SMC.readFans()` → `FanInfo` → `FanRow`); this adds the write side without changing what the rows
already show.

Out of scope: temperature → RPM curves, per-fan modes, remembering a manual setting across launches.

## User-facing behaviour

- A segmented control **Auto · Max · Manual** sits at the top of the Fans section and applies to every
  fan at once.
  - **Auto** hands control back to the SMC — the behaviour every Mac has today.
  - **Max** drives every fan to its own ceiling, `F<n>Mx` (5,779 and 6,241 rpm on the M1 Pro this was
    designed on — the two differ, which is why "max" is per fan and not a single number).
  - **Manual** adds a slider to each `FanRow`, ranging over that fan's own `F<n>Mn…F<n>Mx`. A command is
    sent when the slider is released, not on every drag tick.
- The existing rows (actual RPM, range bar, percentage, `→ target` while ramping) are unchanged and keep
  reading live values, so the user sees the fan converge on what they asked for.
- Until the helper is installed the segmented control is replaced by an **"Enable fan control…"**
  button; when the installed helper's version differs from the bundled one it reads **"Update fan
  helper…"**. A failed command snaps the control back to Auto and shows a one-line error under it.
- Manual and Max last for the session only. Every launch starts in Auto and nothing is written to
  UserDefaults.

## Why a root daemon

Reading SMC keys needs no privilege, which is why the read-only section works today. Writing them
(`F<n>Md`, `F<n>Tg`, `Ftst`) is refused unless the caller is root. The app is signed with the
self-signed "StatsBar Local" identity, not a Developer ID, so `SMAppService.daemon` and `SMJobBless`
are not available to it. A LaunchDaemon installed once with an administrator prompt is; a setuid CLI
was rejected because nothing would put the fans back in Auto if the app crashed mid-override.

## Components

### 1. `Sources/Core/FanControl.swift` — pure, tested

The single definition of the wire protocol and the arithmetic, compiled into **both** the app and the
helper so the two cannot drift.

- `FanCommand`: `version`, `ping`, `set(fan: Int, rpm: Double)`, `max`, `auto`. `serialize()` produces
  one ASCII line; `parse(_:)` returns nil for anything malformed (unknown verb, wrong arity, negative or
  non-finite numbers, fan index outside `0..<64`).
- `FanReply`: `ok`, `version(String)`, `error(String)`, with the same parse/serialize pair.
- `clampedTarget(rpm:minimum:maximum:) -> Double?`: nil when the limits are unusable (`maximum <=
  minimum`, either non-finite or negative) or the request is non-finite; otherwise `rpm` clamped into
  `[minimum, maximum]`. Both the helper and the slider use it.
- `maxTargets(for:)`: the per-fan `F<n>Mx` list Max mode writes, skipping fans whose limits fail the
  clamp's checks.

### 2. `Helper/` — `local.statsbar.fanhelper`, runs as root

A separate directory so `build_app.sh`'s `find Sources` does not pull it into the app module.
`build_app.sh` gains a second `swiftc -O` over `Helper/*.swift` plus `Sources/Core/FanControl.swift`,
places the binary in `StatsBar.app/Contents/Resources/`, and signs it with the same identity as the app.

- **SMC access.** Its own small reader/writer (`SMC_CMD_READ_KEYINFO`, `READ_BYTES`, `WRITE_BYTES = 6`).
  The app's `SMC` is `@MainActor`, read-only and tied to the app module, so it is not shared.
- **Write sequence** (Apple Silicon): `Ftst = 1` if the key exists, then `F<n>Md = 1`, then
  `F<n>Tg = rpm` as `flt `. Back to Auto: `F<n>Md = 0` for every fan, then `Ftst = 0`. Each key's
  layout is read with READ_KEYINFO before writing, and a write whose type/size does not match what the
  helper expects is refused rather than attempted. This sequence is to be confirmed on real hardware
  (see Verification) before it is relied on.
- **Socket.** `/var/run/statsbar-fan.sock`, `chown`ed to the installing user's uid (passed to the helper
  as a launch argument in the plist) and `chmod 0600`. Every accepted connection is also checked with
  `getpeereid` against that uid, so another account on the Mac cannot drive the fans. One client at a
  time; a second connection is refused.
- **Protocol.** Line-based, one `FanCommand` per line, one `FanReply` per line back.

### 3. `Sources/Reader/FanController.swift` — app side

An `ObservableObject` owning the socket connection and the current mode (`auto`, `max`,
`manual([Int: Double])`). It sends commands off the main thread and publishes the result. While the
mode is not Auto it sends `ping` every 2 s. It also exposes the helper state (`notInstalled`,
`outdated`, `ready`) that the view uses to pick the button or the segmented control.

### 4. `Sources/Support/FanHelperInstaller.swift`

Install, update and uninstall via one `osascript -e 'do shell script "…" with administrator
privileges'` each: copy the binary to `/Library/PrivilegedHelperTools/local.statsbar.fanhelper`, write
`/Library/LaunchDaemons/local.statsbar.fanhelper.plist` (`RunAtLoad`, `KeepAlive`, the uid argument),
and `launchctl bootout` + `launchctl bootstrap system` it. The installed version is learned by asking
the running helper (`version`), not by reading files.

### 5. View — `BatteryDetailView.swift`

`pinnedFans` gains the mode control (or the enable/update button) under its caption; `FanRow` gains an
optional slider shown only in Manual. The pinned-header height measurement already tracks whatever the
section renders, so the scroll cap needs no change.

## Fail-safe: every path ends in Auto

The helper returns all fans to Auto when any of these happens:

- the client connection closes (app quit, crash or `kill -9` — the kernel closes the socket);
- no command or `ping` arrives for 10 s (app hung with the socket still open);
- system sleep is about to happen (`IORegisterForSystemPower`, `kIOMessageSystemWillSleep`);
- the helper receives `SIGTERM` (uninstall, `launchctl bootout`, shutdown).

The app additionally sends `auto` on `applicationWillTerminate`, but nothing depends on it.

## Testing and verification

- `Tests/StatsBarCoreTests/FanControlTests.swift`: round-trip every command and reply; reject malformed
  lines; clamp below/inside/above range; nil for `max <= min`, NaN and negative limits. The clamp's
  limit guard gets a mutant (guard removed → suite must go red), per the repo convention.
- Whole-tree typecheck as in CLAUDE.md, plus a typecheck of the helper's own source set.
- On this M1 Pro, after the user installs the helper: set fan 1 to 3,000 rpm and watch `F0Ac` converge;
  switch to Max and watch both fans reach their `Mx`; `kill -9` the app and confirm `F0Md` reads 0
  within a few seconds; sleep the Mac in Manual and confirm Auto on wake.
- The install step needs `osascript` and an admin password, which the agent sandbox blocks; the user
  runs it.
