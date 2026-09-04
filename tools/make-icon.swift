import AppKit

// Generates Resources/DockDeck.icns from code so the icon is reproducible and
// the repository carries no opaque binary asset without its source.
// Run via tools/make-icon.sh.

let size: CGFloat = 1024
let outputRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputRoot).appendingPathComponent("DockDeck.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func squircle(in rect: NSRect) -> NSBezierPath {
    // Approximates the macOS app-icon superellipse closely enough at icon sizes.
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.height * 0.2237)
}

func render() -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current else { image.unlockFocus(); return image }
    context.imageInterpolation = .high

    let inset = size * 0.055
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = squircle(in: body)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.24, green: 0.30, blue: 0.44, alpha: 1),
        NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.22, alpha: 1)
    ])
    gradient?.draw(in: path, angle: -90)

    // Hairline rim, the way system icons separate from a dark background.
    NSColor.white.withAlphaComponent(0.16).setStroke()
    path.lineWidth = size * 0.006
    path.stroke()

    // Three stacked shelves, front one accented.
    let shelfWidth = size * 0.52
    let shelfHeight = size * 0.085
    let x = (size - shelfWidth) / 2
    let colors = [
        NSColor.white.withAlphaComponent(0.28),
        NSColor.white.withAlphaComponent(0.55),
        NSColor(calibratedRed: 0.42, green: 0.72, blue: 1.0, alpha: 1.0)
    ]
    for (index, color) in colors.enumerated() {
        let y = size * 0.30 + CGFloat(index) * size * 0.135
        let rect = NSRect(x: x, y: y, width: shelfWidth, height: shelfHeight)
        let shelf = NSBezierPath(roundedRect: rect, xRadius: shelfHeight * 0.42, yRadius: shelfHeight * 0.42)
        color.setFill()
        shelf.fill()
    }
    image.unlockFocus()
    return image
}

let master = render()
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in sizes {
    let pixels = points * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                from: NSRect(x: 0, y: 0, width: size, height: size), operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try data.write(to: iconset.appendingPathComponent(name))
}
print("iconset written to \(iconset.path)")
