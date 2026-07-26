#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cocobat — coconutBattery-style battery health reader, runs in Terminal (macOS)

Usage:
    ./cocobat.py               Mac battery info
    ./cocobat.py --json        Output JSON (for use by other scripts)
    ./cocobat.py --watch 5     Auto-refresh every 5 seconds (Ctrl+C to quit)
    ./cocobat.py --ios         Read iPhone/iPad over USB
                               (requires: brew install libimobiledevice)

Data sources:
    Mac : ioreg -arn AppleSmartBattery  (IOKit registry, no root needed)
    iOS : idevicediagnostics ioregentry AppleSmartBattery (libimobiledevice)
"""

import argparse
import json
import plistlib
import shutil
import subprocess
import sys
import time

# ---------------------------------------------------------------- helpers ---

RESET, BOLD, DIM = "\033[0m", "\033[1m", "\033[2m"
GREEN, YELLOW, RED, CYAN = "\033[32m", "\033[33m", "\033[31m", "\033[36m"
USE_COLOR = sys.stdout.isatty()


def c(txt, color):
    """Colorize output if running in a terminal."""
    return f"{color}{txt}{RESET}" if USE_COLOR else str(txt)


def run(cmd, timeout=5):
    """Run a command safely, return stdout as bytes or empty bytes on error/timeout."""
    try:
        res = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return res.stdout if res.returncode == 0 else b""
    except (subprocess.SubprocessError, OSError):
        return b""


def fix_signed(v):
    """IOKit sometimes returns negative numbers as unsigned 32/64-bit (e.g. Amperage)."""
    if v is None:
        return None
    if v > 0x7FFFFFFFFFFFFFFF:
        v -= 0x10000000000000000
    elif 0x7FFFFFFF < v <= 0xFFFFFFFF:
        v -= 0x100000000
    return v


def bar(pct, width=28):
    pct = max(0.0, min(100.0, pct or 0))
    filled = round(pct / 100 * width)
    return "█" * filled + "░" * (width - filled)


def health_color(pct):
    if pct is None:
        return DIM
    return GREEN if pct >= 80 else YELLOW if pct >= 60 else RED


def fmt_minutes(m):
    if not m or m >= 65535:
        return "calculating..."
    return f"{m // 60}h {m % 60:02d}m"


def decode_mfg_date(v):
    """Intel Macs pack the manufacture date into a single int: day | month<<5 | (year-1980)<<9."""
    try:
        day, month, year = v & 31, (v >> 5) & 15, 1980 + (v >> 9)
        if 1 <= month <= 12 and 1 <= day <= 31 and 2000 <= year <= 2100:
            return f"{day:02d}/{month:02d}/{year}"
    except Exception:
        pass
    return None


def show(v, fmt="{}"):
    return "—" if v is None else fmt.format(v)


# -------------------------------------------------------------- Mac reader ---

def read_mac():
    out = run(["ioreg", "-arn", "AppleSmartBattery"])
    if not out:
        sys.exit("Failed to run ioreg — this script only works on macOS.")

    entries = plistlib.loads(out) if out.strip() else []
    if not entries:
        sys.exit("AppleSmartBattery not found — does this machine have a battery?")
    p = entries[0]

    design = p.get("DesignCapacity") or 0
    maxcap = p.get("AppleRawMaxCapacity") or p.get("MaxCapacity") or 0
    curcap = p.get("AppleRawCurrentCapacity") or p.get("CurrentCapacity") or 0
    volt = (p.get("Voltage") or 0) / 1000.0
    amp = (fix_signed(p.get("Amperage")) or 0) / 1000.0
    adapter = p.get("AdapterDetails") or {}
    mfg = p.get("ManufactureDate")

    return {
        "device": p.get("DeviceName") or "Mac Battery",
        "serial": p.get("Serial") or p.get("BatterySerialNumber") or "",
        "design_mAh": design,
        "full_charge_mAh": maxcap,
        "current_mAh": curcap,
        "charge_pct": round(curcap / maxcap * 100, 1) if maxcap else None,
        "health_pct": round(maxcap / design * 100, 1) if design else None,
        "cycle_count": p.get("CycleCount"),
        "temperature_c": round((p.get("Temperature") or 0) / 100.0, 1),
        "voltage_v": round(volt, 2),
        "amperage_a": round(amp, 2),
        "power_w": round(volt * amp, 1),
        "charging": bool(p.get("IsCharging")),
        "plugged_in": bool(p.get("ExternalConnected")),
        "fully_charged": bool(p.get("FullyCharged")),
        "time_to_empty_min": fix_signed(p.get("AvgTimeToEmpty")),
        "time_to_full_min": fix_signed(p.get("AvgTimeToFull")),
        "adapter_w": adapter.get("Watts"),
        "adapter_name": adapter.get("Name") or adapter.get("Description") or "",
        "mfg_date": decode_mfg_date(mfg) if isinstance(mfg, int) else None,
    }


def print_mac(i):
    header = c(f"🔋 {i['device']}", BOLD)
    if i["serial"]:
        header += c(f"   SN: {i['serial']}", DIM)
    print(header)
    print(c("─" * 48, DIM))

    # --- Current charge ---
    cp = i["charge_pct"]
    print(f"  Charge         {c(show(cp, '{:5.1f}%'), BOLD)}"
          f"   {i['current_mAh']} / {i['full_charge_mAh']} mAh")
    print(f"  {c(bar(cp), CYAN)}")

    # --- Health ---
    hp = i["health_pct"]
    hcol = health_color(hp)
    print(f"  Health         {c(show(hp, '{:5.1f}%'), BOLD)}"
          f"   {i['full_charge_mAh']} / {i['design_mAh']} mAh (design)")
    print(f"  {c(bar(hp), hcol)}")
    print()

    # --- Details ---
    w = i["power_w"]
    if abs(w) < 0.05:
        power = "0 W"
    else:
        power = f"{w:+.1f} W ({'charging' if w > 0 else 'discharging'})"

    rows = [
        ("Cycle count", show(i["cycle_count"])),
        ("Temperature", f"{i['temperature_c']} °C"),
        ("Voltage", f"{i['voltage_v']} V"),
        ("Power", power),
    ]
    if i["plugged_in"] and i["adapter_w"]:
        rows.append(("Adapter", f"{i['adapter_w']} W  {i['adapter_name']}".strip()))
    if i["mfg_date"]:
        rows.append(("Manufacture date", i["mfg_date"]))

    if i["fully_charged"] and i["plugged_in"]:
        status = "Fully charged"
    elif i["charging"]:
        status = f"Charging — full in ~{fmt_minutes(i['time_to_full_min'])}"
    elif i["plugged_in"]:
        status = "Plugged in, not charging"
    else:
        status = f"On battery — ~{fmt_minutes(i['time_to_empty_min'])} remaining"
    rows.append(("Status", status))

    for label, value in rows:
        print(f"  {label:<14} {value}")


# -------------------------------------------------------------- iOS reader ---

def read_ios():
    for tool in ("idevice_id", "ideviceinfo", "idevicediagnostics"):
        if not shutil.which(tool):
            sys.exit("Missing libimobiledevice.\nInstall it with:  brew install libimobiledevice")

    try:
        udids = run(["idevice_id", "-l"]).decode().split()
    except subprocess.CalledProcessError:
        udids = []
    if not udids:
        sys.exit("No iPhone/iPad found over USB.\n"
                 "→ Plug in the cable, unlock the device, tap Trust, then try again.")

    results = []
    for u in udids:
        dev = {"udid": u}
        for key, field in (("DeviceName", "name"),
                           ("ProductType", "model"),
                           ("ProductVersion", "ios")):
            try:
                dev[field] = run(["ideviceinfo", "-u", u, "-k", key]).decode().strip()
            except subprocess.CalledProcessError:
                dev[field] = None

        try:
            raw = run(["idevicediagnostics", "-u", u,
                       "ioregentry", "AppleSmartBattery"])
            reg = plistlib.loads(raw).get("IORegistry", {})
        except subprocess.CalledProcessError:
            dev["error"] = ("Couldn't read diagnostics — "
                            "unlock the device + tap Trust, then try again.")
            results.append(dev)
            continue

        design = reg.get("DesignCapacity") or 0
        maxcap = (reg.get("AppleRawMaxCapacity")
                  or reg.get("NominalChargeCapacity") or 0)
        cur = reg.get("AppleRawCurrentCapacity") or 0
        temp = fix_signed(reg.get("Temperature"))

        dev.update({
            "serial": reg.get("Serial") or "",
            "design_mAh": design or None,
            "full_charge_mAh": maxcap or None,
            "current_mAh": cur or None,
            "health_pct": round(maxcap / design * 100, 1) if design and maxcap else None,
            "charge_pct": round(cur / maxcap * 100, 1) if maxcap and cur else None,
            "cycle_count": reg.get("CycleCount"),
            "temperature_c": round(temp / 100.0, 1) if temp else None,
            "voltage_v": round(reg.get("Voltage") / 1000.0, 2) if reg.get("Voltage") else None,
        })
        results.append(dev)
    return results


def print_ios(devices):
    for d in devices:
        name = d.get("name") or d["udid"]
        sub = " ".join(filter(None, [d.get("model"), f"iOS {d.get('ios')}" if d.get("ios") else None]))
        print(c(f"📱 {name}", BOLD) + (c(f"   {sub}", DIM) if sub else ""))
        print(c("─" * 48, DIM))

        if d.get("error"):
            print(f"  {c(d['error'], RED)}\n")
            continue

        cp, hp = d.get("charge_pct"), d.get("health_pct")
        print(f"  Charge         {c(show(cp, '{:5.1f}%'), BOLD)}"
              f"   {show(d.get('current_mAh'))} / {show(d.get('full_charge_mAh'))} mAh")
        print(f"  {c(bar(cp), CYAN)}")
        print(f"  Health         {c(show(hp, '{:5.1f}%'), BOLD)}"
              f"   {show(d.get('full_charge_mAh'))} / {show(d.get('design_mAh'))} mAh (design)")
        print(f"  {c(bar(hp), health_color(hp))}")
        print()
        print(f"  {'Cycle count':<14} {show(d.get('cycle_count'))}")
        if d.get("temperature_c") is not None:
            print(f"  {'Temperature':<14} {d['temperature_c']} °C")
        if d.get("voltage_v") is not None:
            print(f"  {'Voltage':<14} {d['voltage_v']} V")
        if d.get("serial"):
            print(f"  {'Serial':<14} {d['serial']}")
        if hp is None:
            print(c("  ⚠ Newer iOS versions may block some health keys over USB.", YELLOW))
        print()


# --------------------------------------------------------------------- main --

def main():
    ap = argparse.ArgumentParser(
        description="cocobat — coconutBattery-style battery health CLI")
    ap.add_argument("--json", action="store_true", help="output JSON")
    ap.add_argument("--watch", type=int, metavar="SEC",
                    help="auto-refresh every SEC seconds")
    ap.add_argument("--ios", action="store_true",
                    help="read iPhone/iPad over USB (libimobiledevice)")
    a = ap.parse_args()

    if sys.platform != "darwin" and not a.ios:
        sys.exit("This script requires macOS (reads IOKit via ioreg).")

    def once():
        if a.ios:
            data = read_ios()
            print(json.dumps(data, ensure_ascii=False, indent=2)) if a.json \
                else print_ios(data)
        else:
            data = read_mac()
            print(json.dumps(data, ensure_ascii=False, indent=2)) if a.json \
                else print_mac(data)

    if a.watch:
        try:
            while True:
                print("\033[2J\033[H", end="")   # clear screen
                once()
                time.sleep(a.watch)
        except KeyboardInterrupt:
            print()
    else:
        once()


if __name__ == "__main__":
    main()
