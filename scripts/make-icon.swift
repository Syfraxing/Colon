#!/usr/bin/env swift
// Renders the Emojify app icon programmatically and packs it into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift [--png path/to/preview.png]
//
// Design: a dark glass squircle on the macOS icon grid (824pt body on a 1024pt canvas) with a
// face made of the trigger itself: ":)" turned upright, so the colon becomes the eyes and the
// parenthesis the smile. The smile glows in the Emojify accent, hsl(211 92% 62%).

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let accent = rgb(0.270, 0.608, 0.970)
let accentLight = rgb(0.55, 0.82, 1.0)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Apple-style continuous corner squircle (superellipse, n = 4.6).
func squircle(in rect: CGRect, exponent n: CGFloat = 4.6) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func linear(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func drawIcon(in ctx: CGContext) {
    let shape = squircle(in: body)

    // Drop shadow under the body, as on the macOS icon grid.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0.07, 0.07, 0.08))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: deep neutral glass, slightly lighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        linear([rgb(0.20, 0.205, 0.22), rgb(0.105, 0.105, 0.115), rgb(0.055, 0.055, 0.06)], [0, 0.55, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: []
    )

    // Accent glow pooling behind the smile.
    ctx.drawRadialGradient(
        linear([rgb(0.270, 0.608, 0.970, 0.38), rgb(0.270, 0.608, 0.970, 0.10), rgb(0.270, 0.608, 0.970, 0)], [0, 0.45, 1]),
        startCenter: CGPoint(x: 512, y: 330), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 330), endRadius: 440, options: []
    )

    // Glass sheen: a soft elliptical highlight across the upper half.
    ctx.saveGState()
    let sheen = CGPath(ellipseIn: CGRect(x: body.minX - 180, y: 560, width: body.width + 360, height: 700), transform: nil)
    ctx.addPath(sheen)
    ctx.clip()
    ctx.drawLinearGradient(
        linear([rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0.015)], [0, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: 560), options: []
    )
    ctx.restoreGState()
    ctx.restoreGState()

    // Hairline rim: bright at the top edge fading toward the bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        linear([rgb(1, 1, 1, 0.35), rgb(1, 1, 1, 0.06), rgb(1, 1, 1, 0.12)], [0, 0.6, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: []
    )
    ctx.restoreGState()

    // Eyes: the colon, upright. Rounded vertical pills, crisp white.
    let eyeSize = CGSize(width: 92, height: 136)
    for centerX in [512 - 132, 512 + 132] as [CGFloat] {
        let eye = CGRect(x: centerX - eyeSize.width / 2, y: 560, width: eyeSize.width, height: eyeSize.height)
        let path = CGPath(roundedRect: eye, cornerWidth: eyeSize.width / 2, cornerHeight: eyeSize.width / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: rgb(1, 1, 1, 0.35))
        ctx.addPath(path)
        ctx.setFillColor(rgb(0.97, 0.97, 0.98))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Smile: the parenthesis, a thick rounded arc in an accent gradient with a glow.
    let smile = CGMutablePath()
    smile.addArc(center: CGPoint(x: 512, y: 520), radius: 230,
                 startAngle: .pi * 1.18, endAngle: .pi * 1.82, clockwise: false)
    let stroke = smile.copy(strokingWithWidth: 78, lineCap: .round, lineJoin: .round, miterLimit: 10)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: rgb(0.270, 0.608, 0.970, 0.9))
    ctx.addPath(stroke)
    ctx.setFillColor(accent)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(stroke)
    ctx.clip()
    ctx.drawLinearGradient(
        linear([accentLight, accent, rgb(0.20, 0.47, 0.92)], [0, 0.5, 1]),
        start: CGPoint(x: 512, y: 380), end: CGPoint(x: 512, y: 250), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("emojify-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output.path)")

let args = CommandLine.arguments
if let index = args.firstIndex(of: "--png"), index + 1 < args.count {
    let preview = URL(fileURLWithPath: args[index + 1])
    try render(pixels: 1024).write(to: preview)
    print("Wrote \(preview.path)")
}
