#!/usr/bin/env swift
// Generates Hangprobe's native macOS AppIcon.icns and preview PNGs using CoreGraphics.
// Bold, Dock-legible geometry tuned so 16px, 32px, and 64px minimized icons stay crisp.

import AppKit
import CoreGraphics
import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let assetsDir = root.appendingPathComponent("assets", isDirectory: true)
let iconsetDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Hangprobe-\(UUID().uuidString).iconset", isDirectory: true)

try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconsetDir) }

func renderIcon(pixelSize: Int) -> Data {
    let s = CGFloat(pixelSize)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: s / 1024.0, y: -s / 1024.0)

    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 34, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.38))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.11, blue: 0.18, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    let bgColors = [
        CGColor(srgbRed: 0.145, green: 0.180, blue: 0.290, alpha: 1.0), // #252E4A
        CGColor(srgbRed: 0.082, green: 0.106, blue: 0.180, alpha: 1.0), // #151B2E
        CGColor(srgbRed: 0.055, green: 0.071, blue: 0.125, alpha: 1.0), // #0E1220
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    let glowColors = [
        CGColor(srgbRed: 0.357, green: 0.525, blue: 1.000, alpha: 0.28),
        CGColor(srgbRed: 0.357, green: 0.525, blue: 1.000, alpha: 0.0),
    ] as CFArray
    let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: CGPoint(x: 512, y: 450),
        startRadius: 10,
        endCenter: CGPoint(x: 512, y: 450),
        endRadius: 430,
        options: []
    )

    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 212, y: 544))
    wave.addLine(to: CGPoint(x: 320, y: 544))
    wave.addLine(to: CGPoint(x: 388, y: 380))
    wave.addLine(to: CGPoint(x: 468, y: 676))
    wave.addLine(to: CGPoint(x: 552, y: 292))
    wave.addLine(to: CGPoint(x: 644, y: 544))

    // Bold 56pt stroke so 16px/32px icons stay super sharp
    ctx.saveGState()
    ctx.addPath(wave)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(56)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let waveColors = [
        CGColor(srgbRed: 0.290, green: 0.871, blue: 0.502, alpha: 1.0), // #4ADE80
        CGColor(srgbRed: 0.376, green: 0.647, blue: 0.980, alpha: 1.0), // #60A5FA
        CGColor(srgbRed: 0.984, green: 0.443, blue: 0.522, alpha: 1.0), // #FB7185
    ] as CFArray
    let waveGrad = CGGradient(colorsSpace: colorSpace, colors: waveColors, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(waveGrad, start: CGPoint(x: 212, y: 544), end: CGPoint(x: 650, y: 544), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.move(to: CGPoint(x: 644, y: 544))
    ctx.addLine(to: CGPoint(x: 812, y: 544))
    ctx.setLineCap(.round)
    ctx.setLineWidth(48)
    ctx.setStrokeColor(CGColor(srgbRed: 0.984, green: 0.443, blue: 0.522, alpha: 0.95))
    ctx.strokePath()
    ctx.restoreGState()

    let haloColors = [
        CGColor(srgbRed: 0.99, green: 0.52, blue: 0.58, alpha: 0.46),
        CGColor(srgbRed: 0.96, green: 0.25, blue: 0.37, alpha: 0.0),
    ] as CFArray
    let haloGrad = CGGradient(colorsSpace: colorSpace, colors: haloColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        haloGrad,
        startCenter: CGPoint(x: 644, y: 544),
        startRadius: 8,
        endCenter: CGPoint(x: 644, y: 544),
        endRadius: 112,
        options: []
    )

    ctx.setFillColor(CGColor(srgbRed: 0.984, green: 0.443, blue: 0.522, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: 644 - 54, y: 544 - 54, width: 108, height: 108))

    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.95, blue: 0.96, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: 644 - 24, y: 544 - 24, width: 48, height: 48))

    ctx.restoreGState()

    let rimRect = bodyRect.insetBy(dx: 4, dy: 4)
    let rimPath = CGPath(roundedRect: rimRect, cornerWidth: 181, cornerHeight: 181, transform: nil)
    ctx.addPath(rimPath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15))
    ctx.setLineWidth(8)
    ctx.strokePath()

    let cgImage = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, pixels) in specs {
    let png = renderIcon(pixelSize: pixels)
    try png.write(to: iconsetDir.appendingPathComponent(filename))
    if pixels == 512 && filename == "icon_512x512.png" {
        try png.write(to: assetsDir.appendingPathComponent("hangprobe-icon-512.png"))
    }
}

let icnsURL = assetsDir.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}
print("Regenerated \(icnsURL.path)")
