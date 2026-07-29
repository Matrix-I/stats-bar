// swift-tools-version:6.0
//
// Package.swift exists ONLY to run unit tests — it does not build the app. Shipping builds stay with
// ./build_app.sh, which compiles every file under Sources/ as one module and links Sparkle; nothing
// here replaces or duplicates that. The two coexist because SwiftPM is inert until invoked: `swift
// test` reads this file, `./build_app.sh` never does. Both see the same files, so there is no second
// copy of anything and no list to keep in sync.
//
// The target is the whole of Sources/Core/, which is the tree's PURE layer and the reason this file
// can exist at all. The rule for that directory: no I/O and no live objects — nothing that reads the
// SMC, IOKit, Mach or sysctl, spawns a process, or is an ObservableObject. SwiftUI value types
// (Color) are allowed, since they need no running application. Everything else under Sources/ is
// excluded on purpose: a reader's output is whatever this Mac's sensors say at that second, so
// asserting on it would test the hardware, and the views need an NSApplication.
//
// Adding a pure helper therefore means putting the file in Sources/Core/ — nothing to edit here, and
// `swift test` picks it up. That is deliberate: an explicit file list would silently leave a new file
// untested the day someone forgot to add it. CI greps this directory for forbidden imports so the
// rule is enforced rather than merely documented.
//
// Tests use swift-testing (`import Testing`), not XCTest: XCTest ships with full Xcode, while
// swift-testing ships with the Command Line Tools — the same and only requirement build_app.sh has.

import PackageDescription

let package = Package(
    name: "StatsBar",
    platforms: [.macOS(.v13)],   // keep in step with build_app.sh's -target and LSMinimumSystemVersion
    targets: [
        // Language mode 5, not 6: build_app.sh compiles without -swift-version, so the app is built in
        // mode 5. Letting the tools-version default the tests to mode 6 would make them stricter than
        // the real build, and a file could then fail here while compiling fine in the app — a failure
        // that says nothing about the shipped binary.
        .target(name: "StatsBarCore", path: "Sources/Core",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "StatsBarCoreTests", dependencies: ["StatsBarCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
