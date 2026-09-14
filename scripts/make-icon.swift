// Draws the app icon — a «quantum» envelope in purple — at every size macOS asks for, into an
// .iconset folder that `iconutil -c icns` turns into AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output.iconset>
import CoreGraphics
import Foundation
import ImageIO

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let channel = { (shift: UInt32) in CGFloat((hex >> shift) & 0xFF) / 255 }
    return CGColor(colorSpace: sRGB, components: [channel(16), channel(8), channel(0), alpha])!
}

/// Stops as (colour, alpha, location).
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

/// Point on an orbit centred on the icon, tilted by `tilt` radians.
func orbitPoint(_ t: CGFloat, radii: CGSize, tilt: CGFloat) -> CGPoint {
    let x = radii.width * cos(t), y = radii.height * sin(t)
    return CGPoint(x: 512 + x * cos(tilt) - y * sin(tilt), y: 512 + x * sin(tilt) + y * cos(tilt))
}

func glowDot(_ ctx: CGContext, at p: CGPoint, core: CGFloat, halo: CGFloat) {
    let glow = gradient([(0xFFFFFF, 0.95, 0), (0xF0ABFC, 0.6, 0.3), (0xC026D3, 0, 1)])
    ctx.drawRadialGradient(glow, startCenter: p, startRadius: 0, endCenter: p, endRadius: halo, options: [])
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2))
}

func roundedRect(_ rect: CGRect, _ corner: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
}

/// Drawn on a 1024 grid (Apple's: an 824 pt tile inset 100 pt). Sizes of 32 px and below drop
/// the orbits, which would only be noise there, and enlarge the envelope.
func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let detailed = pixels > 32
    let tile = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.4))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0x2E1065))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0x160430, 1, 0), (0x3B0F7A, 1, 0.5), (0x7C3AED, 1, 1)]),
                           start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let center = CGPoint(x: 512, y: 520)
    ctx.drawRadialGradient(gradient([(0xD946EF, 0.45, 0), (0x9333EA, 0.18, 0.5), (0x7C3AED, 0, 1)]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: 430, options: [])

    let tilts: [CGFloat] = [.pi / 6, .pi / 2, 5 * .pi / 6]
    let radii = CGSize(width: 370, height: 135)
    if detailed {
        // Quantum dust.
        let dust: [(CGFloat, CGFloat, CGFloat)] = [(210, 790, 5), (300, 862, 3), (824, 806, 4), (770, 246, 5),
                                                  (236, 262, 3), (866, 560, 3), (166, 520, 4), (640, 872, 3), (404, 168, 4)]
        ctx.setFillColor(rgb(0xF5D0FE, 0.7))
        for (x, y, r) in dust { ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }

        // Three tilted orbits, atom-style, with the envelope as the nucleus.
        ctx.setLineWidth(12)
        ctx.setStrokeColor(rgb(0xE9D5FF, 0.55))
        for tilt in tilts {
            ctx.saveGState()
            ctx.translateBy(x: 512, y: 512)
            ctx.rotate(by: tilt)
            ctx.strokeEllipse(in: CGRect(x: -radii.width, y: -radii.height, width: radii.width * 2, height: radii.height * 2))
            ctx.restoreGState()
        }
    }

    // The envelope, with a ghost copy behind it: the same mail in two states at once.
    let envelope = detailed ? CGRect(x: 292, y: 372, width: 440, height: 300) : CGRect(x: 232, y: 332, width: 560, height: 380)
    let corner: CGFloat = detailed ? 40 : 56
    if detailed {
        ctx.saveGState()
        ctx.translateBy(x: 46, y: 40)
        ctx.addPath(roundedRect(envelope, corner))
        ctx.setStrokeColor(rgb(0xF0ABFC, 0.45))
        ctx.setLineWidth(8)
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x1A0536, 0.55))
    ctx.addPath(roundedRect(envelope, corner))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedRect(envelope, corner))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 1, 0), (0xEDE9FE, 1, 1)]),
                           start: CGPoint(x: 0, y: envelope.maxY), end: CGPoint(x: 0, y: envelope.minY), options: [])
    ctx.setStrokeColor(rgb(0xC4B5FD))
    ctx.setLineWidth(detailed ? 10 : 18)
    ctx.move(to: CGPoint(x: envelope.minX, y: envelope.minY))
    ctx.addLine(to: CGPoint(x: envelope.midX, y: envelope.midY + 10))
    ctx.addLine(to: CGPoint(x: envelope.maxX, y: envelope.minY))
    ctx.strokePath()
    ctx.setStrokeColor(rgb(0x7C3AED))
    ctx.setLineWidth(detailed ? 22 : 34)
    ctx.move(to: CGPoint(x: envelope.minX + 6, y: envelope.maxY - 6))
    ctx.addLine(to: CGPoint(x: envelope.midX, y: envelope.midY - 20))
    ctx.addLine(to: CGPoint(x: envelope.maxX - 6, y: envelope.maxY - 6))
    ctx.strokePath()
    ctx.restoreGState()

    // Electrons, glowing, on the part of each orbit outside the envelope.
    if detailed {
        for (t, tilt) in zip([0.35, 2.6, 0.15] as [CGFloat], tilts) {
            glowDot(ctx, at: orbitPoint(t, radii: radii, tilt: tilt), core: 16, halo: 60)
        }
    } else {
        glowDot(ctx, at: CGPoint(x: 760, y: 740), core: 44, halo: 110)
    }
    ctx.restoreGState()

    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()
    return ctx.makeImage()!
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for size in sizes {
    let url = outputDirectory.appendingPathComponent("\(size.name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, render(pixels: size.pixels), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
}
