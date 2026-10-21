import Cocoa
let output = CommandLine.arguments[1]
let indexer = CommandLine.arguments.contains("--indexer")
let sizes = [16, 32, 128, 256, 512]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210).fill()
        NSColor(calibratedRed: 0.19, green: 0.32, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 170, y: 260, width: 684, height: 500), xRadius: 105, yRadius: 105).fill()
        NSBezierPath(roundedRect: NSRect(x: 350, y: 690, width: 245, height: 125), xRadius: 38, yRadius: 38).fill()
        NSColor(calibratedRed: 0.84, green: 0.40, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 345, y: 335, width: 330, height: 330)).fill()
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 411, y: 401, width: 198, height: 198)).fill()
        if indexer {
            NSColor(calibratedRed: 0.84, green: 0.40, blue: 0.23, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 680, y: 145, width: 235, height: 235)).fill()
            NSColor.white.setStroke(); let line = NSBezierPath(); line.lineWidth = 22; line.lineCapStyle = .round
            line.move(to: NSPoint(x: 797, y: 315)); line.line(to: NSPoint(x: 797, y: 252)); line.line(to: NSPoint(x: 846, y: 229)); line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/icon_\(size)x\(size)\(suffix).png"))
    }
}
