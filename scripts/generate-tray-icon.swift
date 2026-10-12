#!/usr/bin/env swift
/// Generate NotchTerm menu-bar template icons (18pt @1x/@2x/@3x).
/// Rounded square + top-center capsule notch (Dynamic Island). Stroke 1.5pt.

import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/NotchTerm/Resources"

let pointSize: CGFloat = 18
let strokePt: CGFloat = 1.5

func drawTray(scale: CGFloat) -> NSBitmapImageRep {
    let px = Int((pointSize * scale).rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("bitmap")
    }
    rep.size = NSSize(width: pointSize, height: pointSize)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("context")
    }
    nsCtx.imageInterpolation = .high
    nsCtx.shouldAntialias = true
    NSGraphicsContext.current = nsCtx

    let cg = nsCtx.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: pointSize, height: pointSize))
    NSColor.black.setStroke()
    NSColor.black.setFill()

    // Rounded square (phone / window) — slightly inset for a lighter menu-bar mark.
    let inset: CGFloat = 2.35
    let body = NSRect(
        x: inset,
        y: inset,
        width: pointSize - inset * 2,
        height: pointSize - inset * 2
    )
    let corner: CGFloat = 2.75
    let frame = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
    frame.lineWidth = strokePt
    frame.lineJoinStyle = .round
    frame.stroke()

    // Capsule notch inside the top edge, centered (Dynamic Island / 刘海).
    let notchW: CGFloat = 6.6
    let notchH: CGFloat = 2.9
    let notch = NSRect(
        x: body.midX - notchW / 2,
        y: body.maxY - strokePt * 0.5 - notchH - 0.35,
        width: notchW,
        height: notchH
    )
    let island = NSBezierPath(
        roundedRect: notch,
        xRadius: notchH / 2,
        yRadius: notchH / 2
    )
    island.fill()

    // Simple prompt in the content well — `>_`
    let contentTop = notch.minY - 0.6
    let contentBottom = body.minY + strokePt
    let cy = (contentTop + contentBottom) / 2
    // Group `>_` as a unit and center that unit (underscore pulls weight right).
    let span: CGFloat = 2.5
    let halfH: CGFloat = 2.35
    let gap: CGFloat = 1.55
    let cursorW: CGFloat = 2.7
    let groupW = span + gap + cursorW
    let groupLeft = body.midX - groupW / 2
    let chevronTipX = groupLeft + span
    let chevronBackX = groupLeft

    let chevron = NSBezierPath()
    chevron.lineWidth = strokePt
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: chevronBackX, y: cy + halfH))
    chevron.line(to: NSPoint(x: chevronTipX, y: cy))
    chevron.line(to: NSPoint(x: chevronBackX, y: cy - halfH))
    chevron.stroke()

    let cursorX = chevronTipX + gap
    let cursor = NSBezierPath()
    cursor.lineWidth = strokePt
    cursor.lineCapStyle = .round
    cursor.move(to: NSPoint(x: cursorX, y: cy - halfH))
    cursor.line(to: NSPoint(x: cursorX + cursorW, y: cy - halfH))
    cursor.stroke()

    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String, dpi: Double) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode \(path)")
    }
    try! data.write(to: URL(fileURLWithPath: path))
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    proc.arguments = ["-s", "dpiWidth", "\(dpi)", "-s", "dpiHeight", "\(dpi)", path]
    try? proc.run()
    proc.waitUntilExit()
    print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (scale, name, dpi) in [
    (CGFloat(1), "TrayIconTemplate.png", 72.0),
    (CGFloat(2), "TrayIconTemplate@2x.png", 144.0),
    (CGFloat(3), "TrayIconTemplate@3x.png", 216.0),
] as [(CGFloat, String, Double)] {
    writePNG(drawTray(scale: scale), to: "\(outDir)/\(name)", dpi: dpi)
}
