// Run with an iconset output folder. Draw at each requested size to preserve the fine lines.
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for logical in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = logical * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(size) / 128, y: CGFloat(size) / 128)
        let surface = NSBezierPath(roundedRect: CGRect(x: 7, y: 7, width: 114, height: 114), xRadius: 25, yRadius: 25)
        let navy = NSColor(srgbRed: 0.025, green: 0.12, blue: 0.19, alpha: 1)
        let teal = NSColor(srgbRed: 0.035, green: 0.36, blue: 0.40, alpha: 1)
        NSGradient(starting: navy, ending: teal)!.draw(in: surface, angle: 52)
        let glow = NSColor(srgbRed: 0.52, green: 1, blue: 0.84, alpha: 1)
        for radius: CGFloat in [18, 31, 44] {
            let circle = NSBezierPath(ovalIn: CGRect(x: 64-radius, y: 64-radius, width: 2*radius, height: 2*radius))
            glow.withAlphaComponent(0.48).setStroke()
            circle.lineWidth = 1.8
            circle.stroke()
        }
        let beam = NSBezierPath()
        beam.move(to: CGPoint(x: 64, y: 64))
        beam.appendArc(withCenter: CGPoint(x: 64, y: 64), radius: 44, startAngle: 32, endAngle: 69)
        beam.close()
        glow.withAlphaComponent(0.23).setFill()
        beam.fill()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 64, y: 64))
        line.line(to: CGPoint(x: 101.3, y: 87.3))
        line.lineWidth = 3; line.lineCapStyle = .round
        glow.setStroke(); line.stroke()
        for (x,y,r): (CGFloat,CGFloat,CGFloat) in [(64,64,4),(89,80,4),(34,57,3),(77,23,3)] {
            glow.setFill()
            NSBezierPath(ovalIn: CGRect(x: x-r, y: y-r, width: 2*r, height: 2*r)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(logical)x\(logical)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
