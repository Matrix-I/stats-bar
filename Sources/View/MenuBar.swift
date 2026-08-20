// MenuBar.swift — the images that render in the menu bar itself: the custom battery glyph (drawn as
// a template NSImage), the dual Mac+phone glyph, and the coloured up/down network-rate glyph.
// AppDelegate picks which battery image to show and assigns these to the status-item buttons.

import SwiftUI
import AppKit

/// Draws the charging bolt so it reads at ANY fill level. The bolt is laid down as a solid
/// glyph, but first a slightly larger bolt-shaped halo is knocked out with `.destinationOut`
/// so there's a clean transparent gap between the bolt and the fill behind it. Punching the
/// bolt out with `.destinationOut` *alone* (the old approach) only looked right when the fill
/// reached the bolt: at a low charge — e.g. an iPhone at 17% — the fill stops well short of the
/// centred bolt, so the hole cut through the empty interior and the right of the outline and
/// looked broken. macOS always shows a solid bolt regardless of level, so we do the same.
private func drawChargingBolt(in bodyRect: NSRect, h: CGFloat) {
    guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) else { return }
    let bh = h * 0.92, bw = bh * (bolt.size.width / max(bolt.size.height, 1))
    let br = NSRect(x: bodyRect.midX - bw / 2, y: h / 2 - bh / 2, width: bw, height: bh)
    bolt.draw(in: br.insetBy(dx: -bw * 0.16, dy: -bh * 0.16), from: .zero, operation: .destinationOut, fraction: 1)
    bolt.draw(in: br, from: .zero, operation: .sourceOver, fraction: 1)
}

/// Draws the menu-bar battery as a resolution-independent **template** NSImage:
/// horizontal outline + terminal nub, an inner fill proportional to the real charge
/// level, and (when charging) a bolt drawn by `drawChargingBolt`. A template
/// image is the reliable way to render a custom menu-bar glyph — the system tints it
/// to match the menu bar (white on dark, black on light). A SwiftUI shape view with
/// blend modes instead rendered as a solid dark blob, because `.primary` didn't adapt
/// and the compositing flattened wrong. SF Symbols only ship `.bolt` for the 100%
/// variant, so drawing it ourselves is the only way to show a partial charging battery.
@MainActor
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
        // Kept as wide as "100%" and right-aligned below, so the item's width — and the anchor every
        // open popover is positioned from — does not move as the charge crosses 9% → 10% → 100%. See
        // networkMenuBarImage for why that matters and what it was measured at. dualMenuBarImage
        // composes two of these, so it inherits the fixed width rather than needing its own.
        let labelW = max(ceil(("100%" as NSString).size(withAttributes: attrs).width), ceil(textSize.width))
        let gap: CGFloat = 3
        let bodyW: CGFloat = 21.4                 // battery body width (glyph only)
        let w = labelW + gap + bodyW + 3.6        // + terminal nub

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            // Percentage label on the left, vertically centred, right-aligned within labelW so its
            // right edge stays a fixed distance from the battery body as the digit count changes.
            text.draw(at: NSPoint(x: labelW - ceil(textSize.width), y: (h - textSize.height) / 2 + 0.3),
                      withAttributes: attrs)

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

            if charging { drawChargingBolt(in: bodyRect, h: h) }
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

        if charging { drawChargingBolt(in: bodyRect, h: h) }
        return true
    }
    img.isTemplate = true
    return img
}

/// Compact up/down transfer rate for the menu bar: "↑ 1.2 MB/s" over "↓ 3.4 MB/s", baked into a
/// single NSImage (right-aligned, two lines). Baking it — rather than a SwiftUI VStack — gives a
/// compact, predictable two-line layout.
///
/// The canvas reserves a FIXED width — menuBarRateWidestSample plus the arrow — instead of hugging
/// the current reading. It used to hug it, and the comment here described the consequence without
/// drawing it: "the width only shifts when the rate's digit-count changes". A variableLength
/// NSStatusItem is exactly as wide as the image handed to it, and every popover in this app is shown
/// relative to a status-item button, which NSPopover goes on following for as long as it is open. So
/// each digit-count change moved the button and the open popover jumped with it — measured at 37 pt
/// of horizontal travel for the 31 → 58 pt swing this glyph had between "0 B/s" and "999.0 MB/s".
///
/// A constant width costs a few points of menu bar that idle readings leave blank, and buys a popover
/// that holds still plus a menu bar whose other items stop sliding once a second. The two lines stay
/// right-aligned, so the reserved slack opens on the left and the digits themselves never move.
///
/// The up arrow is red and the down arrow blue, matching the Total upload / download markers in the
/// popover. A coloured menu-bar image can't be a template (templates render monochrome), so the
/// system won't auto-tint it — the rate text is instead drawn in a colour picked from the current
/// appearance (white in dark mode, black in light). The image is rebuilt ~1 Hz, so it re-adapts
/// shortly after a light/dark switch.
@MainActor
func networkMenuBarImage(up: Double, down: Double) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let textColor: NSColor = isDark ? .white : .black

    // One line = a coloured arrow run followed by the rate in the adaptive text colour.
    func line(arrow: String, arrowColor: NSColor, rate: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "\(arrow) ",
                                          attributes: [.font: font, .foregroundColor: arrowColor])
        s.append(NSAttributedString(string: rate, attributes: [.font: font, .foregroundColor: textColor]))
        return s
    }

    let upLine = line(arrow: "↑", arrowColor: .systemRed, rate: menuBarRate(up))
    let downLine = line(arrow: "↓", arrowColor: .systemBlue, rate: menuBarRate(down))
    let lineH = ceil(max(upLine.size().height, downLine.size().height))
    // Reserved width, measured from the sample rather than hardcoded, so it tracks both the font and
    // any change to menuBarRate's banding. max() and not a clamp: an over-range reading still renders
    // in full and widens the item, which is the right trade at a rate no physical link reaches.
    let reserved = ceil(line(arrow: "↑", arrowColor: .systemRed, rate: menuBarRateWidestSample).size().width)
    let w = max(reserved, ceil(max(upLine.size().width, downLine.size().width)))
    let h = lineH * 2

    let img = NSImage(size: NSSize(width: max(w, 1), height: h), flipped: false) { _ in
        // Non-flipped space (origin bottom-left): upload on the top line, download on the bottom,
        // both right-aligned so the right edge stays fixed as the rate's digits change.
        upLine.draw(at: NSPoint(x: w - ceil(upLine.size().width), y: lineH))
        downLine.draw(at: NSPoint(x: w - ceil(downLine.size().width), y: 0))
        return true
    }
    img.isTemplate = false   // coloured — must not be a template
    return img
}

/// A menu-bar glyph made of an SF Symbol followed by a live percentage, baked into a single
/// **template** image (so the system tints it white-on-dark / black-on-light like the battery glyph).
/// Shared by the CPU (`cpu`) and RAM (`memorychip`) items. The number sits in a field kept as wide as
/// "100%" and is right-aligned in it, so the item's width does not change at 9% → 10% → 100% (it used
/// to step 34.8 → 41.8 → 48.8 pt). That is not cosmetic: this item is a popover anchor, and NSPopover
/// follows the button it was shown from — see networkMenuBarImage for the measurement. The colour set
/// on the text is ignored for a template — only its alpha matters.
@MainActor
func symbolPercentMenuBarImage(symbol: String, percent: Int) -> NSImage {
    let h: CGFloat = 13, symH: CGFloat = 12
    let text = "\(percent)%" as NSString
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let textSize = text.size(withAttributes: attrs)

    let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    sym?.isTemplate = true
    let symW = sym.map { symH * ($0.size.width / max($0.size.height, 1)) } ?? 0
    let gap: CGFloat = 3
    // A percentage cannot print wider than "100%", so that measurement is the field — no max() escape
    // hatch is needed here the way it is for an open-ended byte rate. It stays a max() anyway because
    // `percent` is an Int from roundedInt, which saturates rather than trapping and so can arrive
    // absurd from a bad sensor read; a clipped glyph would hide exactly that.
    let field = max(ceil(("100%" as NSString).size(withAttributes: attrs).width), ceil(textSize.width))
    let w = symW + gap + field

    let img = NSImage(size: NSSize(width: max(w, 1), height: h), flipped: false) { _ in
        sym?.draw(in: NSRect(x: 0, y: (h - symH) / 2, width: symW, height: symH),
                  from: .zero, operation: .sourceOver, fraction: 1)
        // Right-aligned in the field, so the digits end on a fixed edge instead of the symbol-to-digit
        // gap staying fixed and the whole number sliding.
        text.draw(at: NSPoint(x: symW + gap + field - ceil(textSize.width),
                              y: (h - textSize.height) / 2 + 0.3), withAttributes: attrs)
        return true
    }
    img.isTemplate = true
    return img
}

/// Bluetooth menu-bar glyph: the Bluetooth rune drawn as a resolution-independent **template**
/// NSImage (so the system tints it white-on-dark / black-on-light like the battery and CPU glyphs).
/// SF Symbols ships no Bluetooth mark — the logo is a trademarked bind-rune — so we stroke it
/// ourselves. The rune is the two long diagonals crossing at the centre, the vertical spine, and the
/// two short connectors from the spine's tips out to the right-hand peaks; the diagonals run through
/// the centre so tick→peak is a single straight segment.
@MainActor
func bluetoothMenuBarImage() -> NSImage {
    let h: CGFloat = 13
    let lw: CGFloat = 1.3
    let hw: CGFloat = 3.1                       // half-width of the rune (spine to peak/tick)
    let w = hw * 2 + lw + 2                      // + a little breathing room so nothing clips

    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let cx = w / 2
        let top = h - lw / 2, bot = lw / 2
        let q = (top - bot) / 4
        let yUp = bot + 3 * q, yDn = bot + q     // upper / lower band heights
        let left = cx - hw, right = cx + hw

        let p = NSBezierPath()
        p.move(to: NSPoint(x: left, y: yUp))     // upper-left tick
        p.line(to: NSPoint(x: right, y: yDn))    // → lower-right peak (through the centre)
        p.line(to: NSPoint(x: cx, y: bot))       // → bottom of the spine
        p.line(to: NSPoint(x: cx, y: top))       // → up the spine to the top
        p.line(to: NSPoint(x: right, y: yUp))    // → upper-right peak
        p.line(to: NSPoint(x: left, y: yDn))     // → lower-left tick (through the centre)
        p.lineWidth = lw
        p.lineJoinStyle = .round
        p.lineCapStyle = .round
        NSColor.black.setStroke()                // colour ignored for a template; only alpha matters
        p.stroke()
        return true
    }
    img.isTemplate = true
    return img
}

/// Control Center menu-bar glyph: a small 2×2 grid ("dashboard of tiles") rendered as a template
/// image so the system tints it white-on-dark / black-on-light like the other glyphs. This is the
/// always-visible hub item; unlike the others it carries no live number, so it's set once at launch.
@MainActor
func controlCenterMenuBarImage() -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let base = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "StatsBar")
        ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "StatsBar")
    let img = base?.withSymbolConfiguration(cfg) ?? base ?? NSImage()
    img.isTemplate = true
    return img
}

/// Mac + iPhone in one menu-bar item: laptop glyph + Mac battery, then iPhone glyph +
/// iPhone battery, all composited into a SINGLE template image. Baking it avoids the
/// HStack reordering the real MenuBarExtra applies to multi-view labels.
@MainActor
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

