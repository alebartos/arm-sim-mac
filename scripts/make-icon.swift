// Draws the ARM Sim app icon (1024x1024 PNG).
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824 pt squircle centred in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Shadow + background gradient.
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, 0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0x0B1F3A).setFill()
tilePath.fill()
ctx.restoreGState()

ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [color(0x0A1A33), color(0x0F4C6E), color(0x12908F)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: 60)

// Circuit traces in the background.
color(0x5FE3D0, 0.18).setStroke()
for i in 0..<9 {
    let p = NSBezierPath()
    p.lineWidth = 6
    let y = tile.minY + 70 + CGFloat(i) * 88
    p.move(to: NSPoint(x: tile.minX - 20, y: y))
    p.line(to: NSPoint(x: tile.minX + 120 + CGFloat(i % 3) * 30, y: y))
    p.line(to: NSPoint(x: tile.minX + 170 + CGFloat(i % 3) * 30, y: y + 40))
    p.stroke()
    let q = NSBezierPath()
    q.lineWidth = 6
    q.move(to: NSPoint(x: tile.maxX + 20, y: y + 30))
    q.line(to: NSPoint(x: tile.maxX - 110 - CGFloat(i % 2) * 40, y: y + 30))
    q.line(to: NSPoint(x: tile.maxX - 150 - CGFloat(i % 2) * 40, y: y - 10))
    q.stroke()
    color(0x5FE3D0, 0.30).setFill()
    NSBezierPath(ovalIn: NSRect(x: tile.minX + 160 + CGFloat(i % 3) * 30, y: y + 30, width: 20, height: 20)).fill()
    NSBezierPath(ovalIn: NSRect(x: tile.maxX - 160 - CGFloat(i % 2) * 40, y: y - 20, width: 20, height: 20)).fill()
}

// Soft highlight on the top half.
NSGradient(colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
ctx.restoreGState()

// Chip pins.
let chip = NSRect(x: 292, y: 292, width: 440, height: 440)
let pinCount = 7
let pinLength: CGFloat = 52
let pinWidth: CGFloat = 26
let pinGradient = NSGradient(colors: [color(0xF2F5F8), color(0xA9B4C0)])!
for i in 0..<pinCount {
    let offset = chip.minX + 52 + CGFloat(i) * (chip.width - 104 - pinWidth) / CGFloat(pinCount - 1)
    let rects = [
        NSRect(x: offset, y: chip.maxY - 6, width: pinWidth, height: pinLength),            // top
        NSRect(x: offset, y: chip.minY - pinLength + 6, width: pinWidth, height: pinLength), // bottom
        NSRect(x: chip.minX - pinLength + 6, y: offset, width: pinLength, height: pinWidth), // left
        NSRect(x: chip.maxX - 6, y: offset, width: pinLength, height: pinWidth),            // right
    ]
    for (k, r) in rects.enumerated() {
        pinGradient.draw(in: NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6), angle: k < 2 ? 0 : 90)
    }
}

// Chip body.
ctx.saveGState()
let body = NSBezierPath(roundedRect: chip, xRadius: 48, yRadius: 48)
let bodyShadow = NSShadow()
bodyShadow.shadowColor = color(0x000000, 0.45)
bodyShadow.shadowBlurRadius = 24
bodyShadow.shadowOffset = NSSize(width: 0, height: -10)
bodyShadow.set()
color(0x1B2027).setFill()
body.fill()
ctx.restoreGState()
NSGradient(colors: [color(0x353C46), color(0x161A20)])!.draw(in: body, angle: -90)
color(0xFFFFFF, 0.10).setStroke()
body.lineWidth = 4
body.stroke()

// Inner die outline.
let die = chip.insetBy(dx: 44, dy: 44)
let diePath = NSBezierPath(roundedRect: die, xRadius: 26, yRadius: 26)
color(0x5FE3D0, 0.22).setStroke()
diePath.lineWidth = 3
diePath.stroke()

// Digital waveform (logic analyzer style).
let wave = NSBezierPath()
wave.lineWidth = 16
wave.lineJoinStyle = .round
wave.lineCapStyle = .round
let low = die.minY + 70, high = die.minY + 160
let xs: [CGFloat] = [die.minX + 30, die.minX + 95, die.minX + 165, die.minX + 230, die.minX + 290, die.maxX - 30]
wave.move(to: NSPoint(x: xs[0], y: low))
var level = low
for x in xs.dropFirst() {
    wave.line(to: NSPoint(x: x, y: level))
    level = level == low ? high : low
    if x != xs.last { wave.line(to: NSPoint(x: x, y: level)) }
}
ctx.saveGState()
let glow = NSShadow()
glow.shadowColor = color(0x3DFF8C, 0.9)
glow.shadowBlurRadius = 18
glow.set()
color(0x3DFF8C).setStroke()
wave.stroke()
ctx.restoreGState()

// Yellow program-counter arrow.
let arrow = NSBezierPath()
let ax = die.minX + 22, ay = die.maxY - 100
arrow.move(to: NSPoint(x: ax, y: ay - 20))
arrow.line(to: NSPoint(x: ax + 58, y: ay - 20))
arrow.line(to: NSPoint(x: ax + 58, y: ay - 46))
arrow.line(to: NSPoint(x: ax + 110, y: ay))
arrow.line(to: NSPoint(x: ax + 58, y: ay + 46))
arrow.line(to: NSPoint(x: ax + 58, y: ay + 20))
arrow.line(to: NSPoint(x: ax, y: ay + 20))
arrow.close()
NSGradient(colors: [color(0xFFE066), color(0xF5B000)])!.draw(in: arrow, angle: -90)
color(0x7A5600, 0.6).setStroke()
arrow.lineWidth = 4
arrow.stroke()

// Label.
let font = NSFont.systemFont(ofSize: 92, weight: .heavy)
let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: 92) ?? font
let label = NSAttributedString(string: "SIM", attributes: [
    .font: rounded, .foregroundColor: color(0xFFFFFF), .kern: 6,
])
let labelSize = label.size()
label.draw(at: NSPoint(x: ax + 128, y: ay - labelSize.height / 2 + 4))

// Pin-1 marker.
color(0x5FE3D0, 0.8).setFill()
NSBezierPath(ovalIn: NSRect(x: chip.minX + 26, y: chip.minY + 26, width: 22, height: 22)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
