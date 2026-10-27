#!/usr/bin/env swift
// Draws the lookaway app icon with CoreGraphics and writes Resources/AppIcon.icns.
// An open eye whose pupil is a padlock, on a macOS-style rounded square.
//
//   swift scripts/make-icon.swift [output.icns]      (default: Resources/AppIcon.icns)
//
// Run from the lookaway/ directory (scripts/make-icon does that). Needs iconutil.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the icon on a 1024-unit canvas scaled to `px` pixels.
func drawIcon(px: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a].map { CGFloat($0) })!
    }

    // Background: the standard 824-unit body with a 100-unit margin, soft vertical gradient.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space, colors: [color(0.33, 0.40, 0.95), color(0.12, 0.14, 0.45)] as CFArray, locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Eye: an almond between two corners, white.
    let left = CGPoint(x: 190, y: 512), right = CGPoint(x: 834, y: 512)
    let eye = CGMutablePath()
    eye.move(to: left)
    eye.addCurve(to: right, control1: CGPoint(x: 330, y: 760), control2: CGPoint(x: 694, y: 760))
    eye.addCurve(to: left, control1: CGPoint(x: 694, y: 264), control2: CGPoint(x: 330, y: 264))
    eye.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
    ctx.setFillColor(color(0.98, 0.98, 1))
    ctx.addPath(eye)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Iris.
    ctx.setFillColor(color(0.20, 0.25, 0.70))
    ctx.fillEllipse(in: CGRect(x: 512 - 150, y: 512 - 150, width: 300, height: 300))

    // Pupil: a padlock. Shackle first (stroked arc), then the body over it.
    ctx.setStrokeColor(color(1, 1, 1))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: 512, y: 544), radius: 54, startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.move(to: CGPoint(x: 458, y: 544))
    ctx.addLine(to: CGPoint(x: 458, y: 510))
    ctx.move(to: CGPoint(x: 566, y: 544))
    ctx.addLine(to: CGPoint(x: 566, y: 510))
    ctx.strokePath()
    let lock = CGRect(x: 512 - 78, y: 512 - 94, width: 156, height: 116)
    ctx.setFillColor(color(1, 1, 1))
    ctx.addPath(CGPath(roundedRect: lock, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.fillPath()
    // Keyhole.
    ctx.setFillColor(color(0.20, 0.25, 0.70))
    ctx.fillEllipse(in: CGRect(x: 512 - 17, y: 512 - 45, width: 34, height: 34))
    ctx.fill(CGRect(x: 512 - 8, y: 512 - 72, width: 16, height: 40))

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("lookaway-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// The sizes iconutil expects: 16, 32, 128, 256, 512 points at 1x and 2x.
for points in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(px: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(drawIcon(px: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
