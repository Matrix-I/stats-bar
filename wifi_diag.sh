#!/bin/bash
# wifi_diag.sh — diagnose why an iPhone isn't detected over Wi-Fi sync.
# Run this WITH the iPhone in the failing state (charge-only cable or no cable,
# on the same Wi-Fi, "Sync over Wi-Fi" enabled in Finder).

BIN=/opt/homebrew/bin
echo "libimobiledevice: $($BIN/idevice_id -v 2>&1 | head -1)"
echo

echo "=== USB devices (idevice_id -l) ==="
usb=$($BIN/idevice_id -l 2>&1); echo "${usb:-<empty>}"
echo

echo "=== NETWORK devices (idevice_id -n) ==="
net=$($BIN/idevice_id -n 2>&1); echo "${net:-<empty>}"
echo

# Pick the first network-only UDID to probe reads over -n.
udid=$(echo "$net" | grep -v '^$' | head -1)
if [ -n "$udid" ]; then
    echo "=== Reading device $udid over -n ==="
    echo "-- name --";    $BIN/ideviceinfo -n -u "$udid" -k DeviceName 2>&1
    echo "-- battery domain --"
    $BIN/ideviceinfo -n -u "$udid" -q com.apple.mobile.battery 2>&1
    echo "-- diagnostics ioregentry (needs unlock) --"
    $BIN/idevicediagnostics -n -u "$udid" ioregentry AppleSmartBattery 2>&1 | head -20
else
    echo "No network device to probe. Wi-Fi enumeration returned nothing —"
    echo "this is why the iPhone vanishes: the app can only show what -n lists."
fi
