// Draws the app icon (Resources/AppIcon.icns). Run: swift Scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: rect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.42, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.62, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.93, green: 0.33, blue: 0.40, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    // film strip band
    let band = CGRect(x: rect.minX, y: rect.midY - 150 * s, width: rect.width, height: 300 * s)
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.fill(band)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    var x = rect.minX + 30 * s
    while x < rect.maxX - 30 * s {
        for y in [band.minY + 22 * s, band.maxY - 58 * s] {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 44 * s, height: 36 * s), cornerWidth: 7 * s, cornerHeight: 7 * s, transform: nil))
        }
        x += 78 * s
    }
    ctx.fillPath()
    // frames
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    for i in 0..<3 {
        let fx = rect.minX + 40 * s + CGFloat(i) * 258 * s
        ctx.fill(CGRect(x: fx, y: band.minY + 76 * s, width: 230 * s, height: 148 * s))
    }
    ctx.restoreGState()
    // scissors symbol
    let config = NSImage.SymbolConfiguration(pointSize: 380 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let r = CGRect(x: 512 * s - sym.size.width / 2, y: 512 * s - sym.size.height / 2, width: sym.size.width, height: sym.size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        sym.draw(in: r)
        ctx.restoreGState()
    }
    img.unlockFocus()
    return img
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        render(px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
