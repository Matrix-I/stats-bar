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
/// The canvas is sized to the actual two lines so the item sits snug against its content, like the
/// CPU/RAM items — no reserved slack for a hypothetical maximum rate. Monospaced digits keep the two
/// lines aligned and mean the width only shifts when the rate's digit-count changes (e.g. "9 KB/s" →
/// "12 KB/s"), not on every update. The two lines right-align, so the shorter one's right edge lines
/// up with the other.
///
/// The up arrow is red and the down arrow blue, matching the Total upload / download markers in the
/// popover. A coloured menu-bar image can't be a template (templates render monochrome), so the
/// system won't auto-tint it — the rate text is instead drawn in a colour picked from the current
/// appearance (white in dark mode, black in light). The image is rebuilt ~1 Hz, so it re-adapts
/// shortly after a light/dark switch.
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
    // Snug width: just the wider of the two actual lines, so the item hugs its content instead of
    // reserving space for a maximum rate that never shows.
    let w = ceil(max(upLine.size().width, downLine.size().width))
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
/// Shared by the CPU (`cpu`) and RAM (`memorychip`) items. Monospaced digits and a fixed layout keep
/// the item from jittering as the number changes width. The colour set on the text is ignored for a
/// template — only its alpha matters.
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
    let w = symW + gap + ceil(textSize.width)

    let img = NSImage(size: NSSize(width: max(w, 1), height: h), flipped: false) { _ in
        sym?.draw(in: NSRect(x: 0, y: (h - symH) / 2, width: symW, height: symH),
                  from: .zero, operation: .sourceOver, fraction: 1)
        text.draw(at: NSPoint(x: symW + gap, y: (h - textSize.height) / 2 + 0.3), withAttributes: attrs)
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
func controlCenterMenuBarImage() -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let base = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "StatsBar")
        ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "StatsBar")
    let img = base?.withSymbolConfiguration(cfg) ?? base ?? NSImage()
    img.isTemplate = true
    return img
}

/// Short bytes/sec for the menu bar — one significant decimal from KB up, so the label stays narrow.
private func menuBarRate(_ bytesPerSec: Double) -> String {
    let v = max(0, bytesPerSec)
    if v < 1000 { return String(format: "%.0f B/s", v) }
    let kb = v / 1000
    if kb < 1000 { return String(format: "%.0f KB/s", kb) }
    let mb = kb / 1000
    if mb < 1000 { return String(format: "%.1f MB/s", mb) }
    return String(format: "%.1f GB/s", mb / 1000)
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

