// Draws the app icon: an hourglass running out, on the macOS icon grid. No SF Symbols (Apple's terms do not
// allow them in app icons). Run from the repository root:
//
//   swift scripts/make-icon.swift Assets/AppIcon.icns [--preview preview.png]
import AppKit
import SwiftUI

let arguments = CommandLine.arguments.dropFirst()
guard let output = arguments.first else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.icns> [--preview <png>]\n".utf8))
    exit(2)
}
let preview = arguments.firstIndex(of: "--preview").map { arguments[arguments.index(after: $0)] }

/// Draws on a 1024-point grid with a top-left origin. `detailed` is false for 16 and 32 point icons.
func draw(in context: CGContext, pixels: CGFloat, detailed: Bool) {
    context.saveGState()
    context.scaleBy(x: pixels / 1024, y: -pixels / 1024)
    context.translateBy(x: 0, y: -1024)

    // Body: the macOS icon shape, an 824-point rounded rectangle with continuous corners (radius 185.4), with
    // a soft shadow. macOS 26 and later show an icon whose shape differs from this one shrunk inside a gray
    // tile; a superellipse (n = 5) was enough to trigger that, so the shape comes from SwiftUI, not by hand.
    let body = RoundedRectangle(cornerRadius: 185.4, style: .continuous)
        .path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath
    context.saveGState()
    // Shadow offset and blur are in device pixels (the scale above does not apply), so scale them by hand.
    // Unscaled, a 64-pixel icon got the 1024-pixel shadow and it was cut off at the canvas edge.
    let unit = pixels / 1024
    context.setShadow(
        offset: CGSize(width: 0, height: -12 * unit), blur: 24 * unit,
        color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.addPath(body)
    context.setFillColor(NSColor(srgbRed: 0.16, green: 0.17, blue: 0.40, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(body)
    context.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            NSColor(srgbRed: 0.13, green: 0.14, blue: 0.33, alpha: 1).cgColor,
            NSColor(srgbRed: 0.31, green: 0.22, blue: 0.56, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    context.restoreGState()

    // Glass: two bulbs meeting at a narrow neck.
    let glass = CGMutablePath()
    glass.move(to: CGPoint(x: 332, y: 300))
    glass.addLine(to: CGPoint(x: 692, y: 300))
    glass.addCurve(to: CGPoint(x: 530, y: 500), control1: CGPoint(x: 692, y: 420), control2: CGPoint(x: 554, y: 460))
    glass.addLine(to: CGPoint(x: 530, y: 524))
    glass.addCurve(to: CGPoint(x: 692, y: 724), control1: CGPoint(x: 554, y: 564), control2: CGPoint(x: 692, y: 604))
    glass.addLine(to: CGPoint(x: 332, y: 724))
    glass.addCurve(to: CGPoint(x: 494, y: 524), control1: CGPoint(x: 332, y: 604), control2: CGPoint(x: 470, y: 564))
    glass.addLine(to: CGPoint(x: 494, y: 500))
    glass.addCurve(to: CGPoint(x: 332, y: 300), control1: CGPoint(x: 470, y: 460), control2: CGPoint(x: 332, y: 420))
    glass.closeSubpath()

    context.addPath(glass)
    context.setFillColor(NSColor.white.withAlphaComponent(detailed ? 0.16 : 0.24).cgColor)
    context.fillPath()

    // Sand: a little left on top, a mound at the bottom, a thin stream between them.
    let sand = NSColor(srgbRed: 0.98, green: 0.69, blue: 0.20, alpha: 1).cgColor
    context.saveGState()
    context.addPath(glass)
    context.clip()
    context.setFillColor(sand)
    context.fill(CGRect(x: 300, y: detailed ? 452 : 440, width: 424, height: 80))
    // The mound rises from the walls, so it meets the glass without a gap or a step.
    let mound = CGMutablePath()
    mound.move(to: CGPoint(x: 300, y: 740))
    mound.addLine(to: CGPoint(x: 300, y: 700))
    mound.addCurve(to: CGPoint(x: 512, y: 596), control1: CGPoint(x: 380, y: 690), control2: CGPoint(x: 444, y: 596))
    mound.addCurve(to: CGPoint(x: 724, y: 700), control1: CGPoint(x: 580, y: 596), control2: CGPoint(x: 644, y: 690))
    mound.addLine(to: CGPoint(x: 724, y: 740))
    mound.closeSubpath()
    context.addPath(mound)
    context.fillPath()
    if detailed {
        context.setStrokeColor(sand)
        context.setLineWidth(10)
        context.move(to: CGPoint(x: 512, y: 512))
        context.addLine(to: CGPoint(x: 512, y: 600))
        context.strokePath()
    }
    context.restoreGState()

    context.addPath(glass)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    context.setLineWidth(detailed ? 20 : 36)
    context.setLineJoin(.round)
    context.strokePath()

    // Caps above and below the glass.
    context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    for y in [236.0, 732.0] {
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 300, y: y, width: 424, height: 56), cornerWidth: 28, cornerHeight: 28,
                transform: nil))
        context.fillPath()
    }
    context.restoreGState()
}

func png(pixels: Int, detailed: Bool) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    draw(in: context.cgContext, pixels: CGFloat(pixels), detailed: detailed)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(pixels: points * scale, detailed: points * scale > 64).write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(1) }
if let preview {
    try png(pixels: 1024, detailed: true).write(to: URL(fileURLWithPath: preview))
    let small = preview.replacingOccurrences(of: ".png", with: "-small.png")
    try png(pixels: 64, detailed: false).write(to: URL(fileURLWithPath: small))
}
print("wrote \(output)")
