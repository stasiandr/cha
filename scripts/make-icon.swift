// Draws cha's icon (a cup of tea: cha is tea) and writes src/mac/cha.icns.
//
//   swift scripts/make-icon.swift
//
// macOS icon grid: an 824 pt rounded square centred in 1024 with a soft
// shadow; a green-to-teal gradient, a white cup with steam.
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // The tile, with the shadow macOS icons carry.
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor(srgbRed: 0.12, green: 0.55, blue: 0.45, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.55, green: 0.86, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.69, blue: 0.56, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.47, blue: 0.55, alpha: 1),
    ])!
    gradient.draw(in: tile, angle: -60)
    // A soft light from the top.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: tile, angle: -90)

    NSColor.white.setFill()
    NSColor.white.setStroke()

    // The cup: a bowl with a flat rim.
    let cup = NSBezierPath()
    cup.move(to: NSPoint(x: 290 * s, y: 560 * s))
    cup.line(to: NSPoint(x: 690 * s, y: 560 * s))
    cup.curve(
        to: NSPoint(x: 560 * s, y: 330 * s), controlPoint1: NSPoint(x: 690 * s, y: 430 * s),
        controlPoint2: NSPoint(x: 640 * s, y: 350 * s))
    cup.line(to: NSPoint(x: 420 * s, y: 330 * s))
    cup.curve(
        to: NSPoint(x: 290 * s, y: 560 * s), controlPoint1: NSPoint(x: 340 * s, y: 350 * s),
        controlPoint2: NSPoint(x: 290 * s, y: 430 * s))
    cup.close()
    cup.fill()

    // The handle.
    let handle = NSBezierPath()
    handle.lineWidth = 34 * s
    handle.appendArc(
        withCenter: NSPoint(x: 690 * s, y: 480 * s), radius: 58 * s, startAngle: 120,
        endAngle: -80, clockwise: true)
    handle.stroke()

    // The saucer.
    NSBezierPath(roundedRect: r(250, 280, 480, 34), xRadius: 17 * s, yRadius: 17 * s).fill()

    // Steam: two soft S curves.
    for (x, height) in [(420.0, 170.0), (540.0, 200.0)] {
        let steam = NSBezierPath()
        steam.lineWidth = 30 * s
        steam.lineCapStyle = .round
        steam.move(to: NSPoint(x: x * s, y: 600 * s))
        steam.curve(
            to: NSPoint(x: x * s, y: (600 + height) * s),
            controlPoint1: NSPoint(x: (x - 60) * s, y: (600 + height * 0.35) * s),
            controlPoint2: NSPoint(x: (x + 60) * s, y: (600 + height * 0.65) * s))
        NSColor.white.withAlphaComponent(0.85).setStroke()
        steam.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("cha.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: pixels).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
let preview = draw(size: 1024).representation(using: .png, properties: [:])!
try! preview.write(to: root.appendingPathComponent("build/icon-preview.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("src/mac/cha.icns").path]
try! process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "wrote src/mac/cha.icns" : "iconutil failed")
