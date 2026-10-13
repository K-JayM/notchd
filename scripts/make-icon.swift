// Draws the notchd app icon (1024×1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824pt squircle centred in 1024, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(squircle); ctx.setFillColor(color(0x0B0B12)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
// Background: deep violet to near black.
ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [color(0x2E2350), color(0x0C0B14)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Pink/violet glow behind the island.
ctx.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: [color(0xFF4FA3, 0.55), color(0x8A5CFF, 0.18), color(0x8A5CFF, 0)] as CFArray,
                                  locations: [0, 0.45, 1])!,
                       startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 500), endRadius: 420, options: [])
// Fine top highlight, like glass.
ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
ctx.restoreGState()

// The island.
let island = CGRect(x: 512 - 300, y: 512 - 82, width: 600, height: 164)
let islandPath = CGPath(roundedRect: island, cornerWidth: 82, cornerHeight: 82, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: color(0x000000, 0.6))
ctx.addPath(islandPath); ctx.setFillColor(color(0x000000)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(islandPath); ctx.setStrokeColor(color(0xFFFFFF, 0.12)); ctx.setLineWidth(3); ctx.strokePath()

// Cover art on the left.
let art = CGRect(x: island.minX + 44, y: island.midY - 44, width: 88, height: 88)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: art, cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [color(0xFF8A4C), color(0xFF4FA3), color(0x8A5CFF)] as CFArray,
                                  locations: [0, 0.5, 1])!,
                       start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
ctx.restoreGState()

// Sound bars on the right.
let heights: [CGFloat] = [46, 92, 64, 110, 58]
let barWidth: CGFloat = 20, gap: CGFloat = 14
var x = island.maxX - 44 - CGFloat(heights.count) * barWidth - CGFloat(heights.count - 1) * gap
for h in heights {
    let bar = CGRect(x: x, y: island.midY - h / 2, width: barWidth, height: h)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [color(0xFF6FB5), color(0x9B6BFF)] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: bar.maxY), end: CGPoint(x: 0, y: bar.minY), options: [])
    ctx.restoreGState()
    x += barWidth + gap
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
