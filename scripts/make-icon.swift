// Draws Radian's app icon and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// The mark is a radian: the angle whose arc is as long as the circle's radius.
import AppKit

let canvas: CGFloat = 1024

func drawIcon(in context: CGContext) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            colorSpace: colorSpace,
            components: [
                CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
            ]
        )!
    }

    // The rounded tile, on Apple's 824pt grid inside a 1024pt canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    context.addPath(tilePath)
    context.setFillColor(color(0x5B6CF0))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0x4F63EE), color(0xA06BEA), color(0xFF8E6E)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY),
        options: []
    )
    context.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 236
    let stroke: CGFloat = 46
    let start: CGFloat = 18 * .pi / 180
    let end = start + 1 // exactly one radian

    // The full circle, faint.
    context.setLineWidth(stroke)
    context.setStrokeColor(color(0xFFFFFF, 0.26))
    context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    context.strokePath()

    // The wedge: two radii and the arc between them.
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(color(0xFFFFFF))
    context.move(to: CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start)))
    context.addLine(to: center)
    context.addLine(to: CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end)))
    context.strokePath()
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    context.strokePath()
}

func png(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    let scale = CGFloat(pixels) / canvas
    graphics.cgContext.scaleBy(x: scale, y: scale)
    drawIcon(in: graphics.cgContext)
    return bitmap.representation(using: .png, properties: [:])!
}

let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Radian-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")
