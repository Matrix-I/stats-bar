// MenuBar.swift — everything that renders in the menu bar itself: the custom battery glyph
// (drawn as a template NSImage), the dual Mac+phone glyph, and the MenuBarLabel view that
// picks which of them to show.

import SwiftUI
import AppKit

/// Draws the menu-bar battery as a resolution-independent **template** NSImage:
/// horizontal outline + terminal nub, an inner fill proportional to the real charge
/// level, and (when charging) a bolt punched out via `.destinationOut`. A template
/// image is the reliable way to render a custom menu-bar glyph — the system tints it
/// to match the menu bar (white on dark, black on light). A SwiftUI shape view with
/// blend modes instead rendered as a solid dark blob, because `.primary` didn't adapt
/// and the compositing flattened wrong. SF Symbols only ship `.bolt` for the 100%
/// variant, so drawing it ourselves is the only way to show a partial charging battery.
func batteryMenuBarImage(level: Double, charging: Bool, percent: Int? = nil) -> NSImage {
    let h: CGFloat = 13
    let lw: CGFloat = 1.2

    // --- Number-left style: the % is drawn as a label to the LEFT of the battery
    // glyph, and the glyph itself uses the proportional fill (same as the hidden-%
    // fill style). Total width = label + gap + battery body + terminal nub. ---
    if let percent {
        let text = "\(percent)%" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.size(withAttributes: attrs)
        let labelW = ceil(textSize.width)
        let gap: CGFloat = 3
        let bodyW: CGFloat = 21.4                 // battery body width (glyph only)
        let w = labelW + gap + bodyW + 3.6        // + terminal nub

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            // Percentage label on the left, vertically centred.
            text.draw(at: NSPoint(x: 0, y: (h - textSize.height) / 2 + 0.3), withAttributes: attrs)

            // Battery glyph to the right of the label.
            let bx = labelW + gap
            let bodyRect = NSRect(x: bx + lw / 2, y: lw / 2, width: bodyW, height: h - lw)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: bodyRect, xRadius: 3.4, yRadius: 3.4)
            outline.lineWidth = lw
            outline.stroke()

            let inner = bodyRect.insetBy(dx: lw + 0.7, dy: lw + 0.7)
            let fillW = max(1.5, inner.width * min(max(level, 0), 1))
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height),
                         xRadius: 1.6, yRadius: 1.6).fill()

            NSBezierPath(roundedRect: NSRect(x: bx + bodyW + 0.6, y: h / 2 - 2.4, width: 1.7, height: 4.8),
                         xRadius: 0.8, yRadius: 0.8).fill()

            if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
                let bh = h * 0.92, bw = bh * (bolt.size.width / max(bolt.size.height, 1))
                let br = NSRect(x: bodyRect.midX - bw / 2, y: h / 2 - bh / 2, width: bw, height: bh)
                bolt.draw(in: br, from: .zero, operation: .destinationOut, fraction: 1)
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // --- Fill style: used when the % is hidden — a plain glyph with a proportional fill. ---
    let w: CGFloat = 25
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let bodyW = w - 3.6                       // leave room for the terminal nub
        let bodyRect = NSRect(x: lw / 2, y: lw / 2, width: bodyW, height: h - lw)
        NSColor.black.setStroke()                 // color ignored for templates; only alpha matters
        let outline = NSBezierPath(roundedRect: bodyRect, xRadius: 3.4, yRadius: 3.4)
        outline.lineWidth = lw
        outline.stroke()

        let inner = bodyRect.insetBy(dx: lw + 0.7, dy: lw + 0.7)
        let fillW = max(1.5, inner.width * min(max(level, 0), 1))
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height),
                     xRadius: 1.6, yRadius: 1.6).fill()

        NSBezierPath(roundedRect: NSRect(x: bodyW + 0.6, y: h / 2 - 2.4, width: 1.7, height: 4.8),
                     xRadius: 0.8, yRadius: 0.8).fill()

        if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            let bh = h * 0.92, bw = bh * (bolt.size.width / max(bolt.size.height, 1))
            let br = NSRect(x: bodyRect.midX - bw / 2, y: h / 2 - bh / 2, width: bw, height: bh)
            bolt.draw(in: br, from: .zero, operation: .destinationOut, fraction: 1)
        }
        return true
    }
    img.isTemplate = true
    return img
}

/// Thin SwiftUI wrapper around the template battery image.
struct BatteryGlyph: View {
    let level: Double        // 0…1
    let charging: Bool
    var percent: Int? = nil  // when set, the number is drawn inside the battery
    var body: some View {
        Image(nsImage: batteryMenuBarImage(level: level, charging: charging, percent: percent))
    }
}

/// Mac + iPhone in one menu-bar item: laptop glyph + Mac battery, then iPhone glyph +
/// iPhone battery, all composited into a SINGLE template image. Baking it avoids the
/// HStack reordering the real MenuBarExtra applies to multi-view labels.
func dualMenuBarImage(macPct: Int, macCharging: Bool, phonePct: Int, phoneCharging: Bool,
                       phoneSymbol: String, showPercent: Bool) -> NSImage {
    let h: CGFloat = 13, symH: CGFloat = 10
    let macBat = batteryMenuBarImage(level: Double(macPct) / 100, charging: macCharging, percent: showPercent ? macPct : nil)
    let phoneBat = batteryMenuBarImage(level: Double(phonePct) / 100, charging: phoneCharging, percent: showPercent ? phonePct : nil)
    func symbol(_ name: String) -> NSImage? {
        guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        s.isTemplate = true
        return s
    }
    let laptop = symbol("laptopcomputer"), phone = symbol(phoneSymbol)
    func widthOf(_ img: NSImage?) -> CGFloat {
        guard let img else { return 0 }
        return symH * (img.size.width / max(img.size.height, 1))
    }
    let laptopW = widthOf(laptop), phoneW = widthOf(phone)
    let gap: CGFloat = 2.5, bigGap: CGFloat = 6
    let total = laptopW + gap + macBat.size.width + bigGap + phoneW + gap + phoneBat.size.width

    let img = NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
        var x: CGFloat = 0
        laptop?.draw(in: NSRect(x: x, y: (h - symH) / 2, width: laptopW, height: symH),
                     from: .zero, operation: .sourceOver, fraction: 1)
        x += laptopW + gap
        macBat.draw(in: NSRect(x: x, y: 0, width: macBat.size.width, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1)
        x += macBat.size.width + bigGap
        phone?.draw(in: NSRect(x: x, y: (h - symH) / 2, width: phoneW, height: symH),
                    from: .zero, operation: .sourceOver, fraction: 1)
        x += phoneW + gap
        phoneBat.draw(in: NSRect(x: x, y: 0, width: phoneBat.size.width, height: h),
                      from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    img.isTemplate = true
    return img
}

/// Single menu bar item. Mac-only: one line, battery-shape icon (+ optional %).
/// With "Show iPhone/Android in menu bar" on and a device readable: two compact stacked
/// lines instead — laptop/phone glyphs so the two percentages aren't ambiguous. Only one
/// mobile device is ever shown at a time (iPhone takes priority when both are connected),
/// to keep the menu bar from growing a third glyph.
struct MenuBarLabel: View {
    @ObservedObject var reader: BatteryReader
    @ObservedObject var iosReader: IOSDeviceReader
    @ObservedObject var androidReader: AndroidDeviceReader
    @AppStorage("showMenuBarPercent") private var showMacPercent = true
    @AppStorage("showIPhoneMenuBar") private var showIPhoneMenuBar = false
    @AppStorage("showAndroidMenuBar") private var showAndroidMenuBar = false

    private var iosDevice: IOSDeviceInfo? {
        guard showIPhoneMenuBar,
              let device = iosReader.devices.first,
              device.chargePercent != nil else { return nil }
        return device
    }

    private var androidDevice: AndroidDeviceInfo? {
        guard showAndroidMenuBar,
              let device = androidReader.devices.first,
              device.levelPercent != nil else { return nil }
        return device
    }

    var body: some View {
        let macPct = Int(reader.info.chargePercent.rounded())

        if let ios = iosDevice, let iosCp = ios.chargePercent {
            // Both devices, baked into one image — no HStack for the menu bar to reverse.
            Image(nsImage: dualMenuBarImage(macPct: macPct,
                                            macCharging: reader.info.isCharging,
                                            phonePct: Int(iosCp.rounded()),
                                            phoneCharging: ios.isCharging,
                                            phoneSymbol: "iphone",
                                            showPercent: showMacPercent))
        } else if let android = androidDevice, let level = android.levelPercent {
            Image(nsImage: dualMenuBarImage(macPct: macPct,
                                            macCharging: reader.info.isCharging,
                                            phonePct: level,
                                            phoneCharging: android.isCharging,
                                            phoneSymbol: "candybarphone",
                                            showPercent: showMacPercent))
        } else {
            // Number lives inside the battery, so there's just one element — no HStack
            // ordering for the menu bar to reverse.
            BatteryGlyph(level: reader.info.chargePercent / 100,
                         charging: reader.info.isCharging,
                         percent: showMacPercent ? macPct : nil)
        }
    }
}
