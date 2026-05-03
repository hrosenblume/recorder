// Standalone Swift script that renders a Loom-style app icon and emits Recorder.icns.
// Usage: swift scripts/generate-icon.swift Resources/Recorder.icns
//
// Style: rounded-square purple→pink gradient with a centered white play triangle.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Drawing

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixelSize = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    ) else { fatalError("Could not create bitmap rep") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Rounded-square clip
    let inset = size * 0.10
    let radius = size * 0.225
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
    bgPath.addClip()

    // Gradient fill (indigo → pink, 45°)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.39, green: 0.36, blue: 0.92, alpha: 1.0),
        NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.71, alpha: 1.0)
    ])!
    gradient.draw(in: bgRect, angle: 45)

    // Subtle inner highlight
    let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.18),
        NSColor(white: 1.0, alpha: 0.0)
    ])!
    highlight.draw(in: bgRect, angle: 90)

    // Centered play triangle, white
    let cx = bgRect.midX
    let cy = bgRect.midY
    let tw = bgRect.width * 0.42
    let th = bgRect.height * 0.46
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: cx - tw * 0.32, y: cy - th * 0.5))
    triangle.line(to: NSPoint(x: cx - tw * 0.32, y: cy + th * 0.5))
    triangle.line(to: NSPoint(x: cx + tw * 0.55, y: cy))
    triangle.close()

    NSColor.white.setFill()
    triangle.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - .icns assembly via iconutil

func writeIcns(to outputPath: String) throws {
    let iconsetDir = NSTemporaryDirectory() + "Recorder.iconset"
    try? FileManager.default.removeItem(atPath: iconsetDir)
    try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

    // (logical, scale, filename) per Apple's iconutil layout
    let entries: [(Int, Int, String)] = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png")
    ]

    for (logical, scale, filename) in entries {
        let pixels = CGFloat(logical * scale)
        let rep = drawIcon(size: pixels)
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        let url = URL(fileURLWithPath: iconsetDir).appendingPathComponent(filename)
        try data.write(to: url)
    }

    let outURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: outURL)
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconsetDir, "-o", outputPath]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("iconutil failed\n".utf8))
        exit(1)
    }

    try? FileManager.default.removeItem(atPath: iconsetDir)
}

// MARK: - main

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/Recorder.icns"

do {
    try writeIcns(to: outPath)
    print("Wrote \(outPath)")
} catch {
    FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
    exit(1)
}
