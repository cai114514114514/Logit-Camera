import AppKit
import ImageIO
import UniformTypeIdentifiers

// Run from the project root to regenerate the local app icon without downloads.
let size = 1024
let bitmap = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(red: 0.035, green: 0.04, blue: 0.045, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
// Original geometric artwork; no system symbol artwork is redistributed.
let center = NSPoint(x: 512, y: 512)
for blade in 0..<6 {
    let angle = Double(blade) * .pi / 3
    let points = [NSPoint(x: 110, y: 35), NSPoint(x: 335, y: 35),
                  NSPoint(x: 220, y: 234), NSPoint(x: -5, y: 234)]
    let path = NSBezierPath()
    for (index, point) in points.enumerated() {
        let rotated = NSPoint(x: center.x + point.x * cos(angle) - point.y * sin(angle),
                              y: center.y + point.x * sin(angle) + point.y * cos(angle))
        if index == 0 { path.move(to: rotated) } else { path.line(to: rotated) }
    }
    path.close()
    NSColor(calibratedHue: 0.13, saturation: 0.87, brightness: 1 - Double(blade) * 0.035, alpha: 1).setFill()
    path.fill()
}
NSGraphicsContext.restoreGraphicsState()
let destination = URL(fileURLWithPath: "LogitCamera/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(writer, bitmap.makeImage()!, nil)
guard CGImageDestinationFinalize(writer) else { fatalError("Could not write app icon") }
