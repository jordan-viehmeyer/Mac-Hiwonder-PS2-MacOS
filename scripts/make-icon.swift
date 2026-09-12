import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Generate the app icon rather than checking a binary .icns into the repo: Command Line
// Tools has no Xcode asset pipeline, and a script keeps the icon reviewable in diffs.
// Drawn straight into a CGContext because NSImage's lockFocus needs a window server.

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ px: Int) -> CGImage? {
    let size = CGFloat(px)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Squircle plate with a vertical gradient.
    let plate = roundedRect(CGRect(x: 0, y: 0, width: size, height: size), size * 0.2237)
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.38, green: 0.44, blue: 0.97, alpha: 1),
                  CGColor(srgbRed: 0.17, green: 0.20, blue: 0.60, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0), options: [])
    }
    ctx.restoreGState()

    // A stylised pad: rounded body, two sticks, a d-pad cross.
    let u = size / 100
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.addPath(roundedRect(CGRect(x: 17 * u, y: 33 * u, width: 66 * u, height: 35 * u),
                            15 * u))
    ctx.fillPath()

    // D-pad on the left, two sticks on the right, laid out so nothing overlaps.
    ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.24, blue: 0.68, alpha: 1))
    let arm = 4.5 * u
    let dpadX = 32.0 * u
    ctx.fill(CGRect(x: dpadX - 7 * u, y: 50 * u - arm / 2, width: 14 * u, height: arm))
    ctx.fill(CGRect(x: dpadX - arm / 2, y: 43 * u, width: arm, height: 14 * u))
    for cx in [56.0, 72.0] {
        let r = 6.5 * u
        ctx.fillEllipse(in: CGRect(x: CGFloat(cx) * u - r, y: 50 * u - r,
                                   width: r * 2, height: r * 2))
    }

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

// iconutil expects this exact set of names.
let entries: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
    (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]
for (px, name) in entries {
    guard let image = render(px) else { continue }
    try write(image, to: out.appendingPathComponent("\(name).png"))
}
print("wrote \(entries.count) icon sizes to \(out.path)")
