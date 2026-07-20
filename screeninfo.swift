// screeninfo.swift — in ra thông tin màn hình đúng như StatsBar tính toán.
// Chạy trong Terminal CỦA BẠN (phiên GUI), KHÔNG chạy qua automation:
//     swiftc screeninfo.swift -o /tmp/screeninfo && /tmp/screeninfo
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

print("NSScreen.screens.count = \(NSScreen.screens.count)")
for (i, s) in NSScreen.screens.enumerated() {
    let f = s.frame
    let v = s.visibleFrame
    let isMain = (s == NSScreen.main) ? "  <- NSScreen.main" : ""
    let atOrigin = (f.origin == .zero) ? "  (origin 0,0 = menu-bar screen)" : ""
    print(String(format: "  [%d] frame=%.0fx%.0f @(%.0f,%.0f)  visibleFrame=%.0fx%.0f%@%@",
                 i, f.width, f.height, f.origin.x, f.origin.y,
                 v.width, v.height, atOrigin, isMain))
}

// Đúng logic app đang dùng cho maxPanelHeight:
let screen = NSScreen.screens.first ?? NSScreen.main
if let screen {
    print(String(format: "\nscreens.first -> %.0fx%.0f  visibleFrame.height=%.0f",
                 screen.frame.width, screen.frame.height, screen.visibleFrame.height))
    print(String(format: "maxPanelHeight (cap) = visibleFrame.height * 0.8 = %.0f",
                 screen.visibleFrame.height * 0.8))
}
