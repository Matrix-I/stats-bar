// BatteryBarApp.swift — app entry point for BatteryBar, a menu bar battery health app
// (coconutBattery-style).
//
// Requires : macOS 13 Ventura or later + Xcode Command Line Tools
//            (xcode-select --install)
//
// Build/run     :  ./build_app.sh        (compiles the whole Sources/ tree into BatteryBar.app)
// Package .dmg  :  ./build_dmg.sh
//
// Data is read directly from the IOKit registry "AppleSmartBattery" (see BatteryReader) — the
// same source coconutBattery uses. No root needed, no kernel extension. Live power rails + fan
// speeds come from the AppleSMC user client (see SMC); iPhone/Android come over USB via
// libimobiledevice / adb (see IOSDeviceReader / AndroidDeviceReader).

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the Dock icon when running as a bare binary (the .app bundle uses LSUIElement)
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct BatteryBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var reader = BatteryReader()
    @StateObject private var iosReader = IOSDeviceReader()
    @StateObject private var androidReader = AndroidDeviceReader()

    var body: some Scene {
        MenuBarExtra {
            BatteryDetailView(reader: reader, iosReader: iosReader, androidReader: androidReader)
        } label: {
            MenuBarLabel(reader: reader, iosReader: iosReader, androidReader: androidReader)
        }
        .menuBarExtraStyle(.window)
    }
}
