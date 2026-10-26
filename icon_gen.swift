// icon_gen.swift — generates AppIcon_1024.png (source art for AppIcon.icns)
// Run: swiftc icon_gen.swift -o icon_gen && ./icon_gen
//
// The art is a chip with a pulse line across it: "live hardware monitor". The previous icon was a
// battery glyph from when the app only read AppleSmartBattery; it now covers CPU, GPU, memory,
// network, fans and attached devices, and a battery read as the narrower app it no longer is.
//
// Drawn with plain Bezier paths rather than an SF Symbol so the shape doesn't shift with whatever
// symbol set the build machine's SDK ships.

import AppKit

let size: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

// Background: the macOS 11+ icon grid puts an 824pt rounded body inside the 1024 canvas and leaves
// the margin for the drop shadow. Full-bleed art looks oversized next to every other Dock icon.
let inset: CGFloat = 100
let bodyRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bgPath = NSBezierPath(roundedRect: bodyRect, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let dropShadow = NSShadow()
dropShadow.shadowBlurRadius = 30
dropShadow.shadowOffset = NSSize(width: 0, height: -12)
dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
dropShadow.set()
rgb(28, 40, 70).setFill()
bgPath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(28, 40, 70), rgb(10, 14, 30)])?.draw(in: bgPath, angle: -90)
NSColor.white.withAlphaComponent(0.08).setStroke()
bgPath.lineWidth = 3
bgPath.stroke()

// Pins: five per side, drawn first so the chip body covers their inner ends.
rgb(150, 170, 210).setFill()
for i in 0..<5 {
    let o = 302 + CGFloat(i) * 92
    for pin in [NSRect(x: o, y: 196, width: 44, height: 80), NSRect(x: o, y: 748, width: 44, height: 80),
                NSRect(x: 196, y: o, width: 80, height: 44), NSRect(x: 748, y: o, width: 80, height: 44)] {
        NSBezierPath(roundedRect: pin, xRadius: 14, yRadius: 14).fill()
    }
}

// Chip body.
let chip = NSBezierPath(roundedRect: NSRect(x: 262, y: 262, width: 500, height: 500), xRadius: 70, yRadius: 70)
NSGradient(colors: [rgb(60, 70, 95), rgb(34, 40, 58)])?.draw(in: chip, angle: -90)
rgb(110, 125, 165).setStroke()
chip.lineWidth = 6
chip.stroke()

// Pulse line, green to match the app's "healthy" color, with a glow so it still reads at 16px.
let y0: CGFloat = 512
let pulse = NSBezierPath()
pulse.move(to: NSPoint(x: 312, y: y0))
for point in [(410, y0), (455, y0 + 150), (520, y0 - 170), (575, y0 + 90), (610, y0), (712, y0)] {
    pulse.line(to: NSPoint(x: CGFloat(point.0), y: point.1))
}
pulse.lineWidth = 40
pulse.lineCapStyle = .round
pulse.lineJoinStyle = .round
let green = NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.44, alpha: 1.0)
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowBlurRadius = 40
glow.shadowColor = green.withAlphaComponent(0.9)
glow.set()
green.setStroke()
pulse.stroke()
NSGraphicsContext.restoreGraphicsState()

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
