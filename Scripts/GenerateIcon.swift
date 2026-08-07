#!/usr/bin/env swift
//
// FrameStation icon generator.
//
//   swift Scripts/GenerateIcon.swift [output-directory]
//
// The icon is code rather than a binary PNG so it re-exports at every size and
// platform variant deterministically, and so a tweak is a diff instead of a
// round trip through a design tool.
//
// Mark: two overlapping rounded-square frames — a library of frames — on a
// deep crimson-to-coral gradient. Two rather than three because a third stroke
// turns to mush at the 40pt size the Settings list uses.
//
// App Store constraints honoured here:
//   • 1024×1024, square, NO alpha channel, sRGB
//   • corners left square — the system applies the mask, pre-rounding double-masks
//   • no text, no Apple hardware, no photographic detail
//
// macOS is the exception: its icons ship pre-rounded with margin, per the HIG.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

struct RGB {
    let r, g, b: CGFloat
    func cg(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }
}

// Dark to vivid to bright, so the plate has depth rather than reading as one
// flat fill at Settings-row size. The mid tone is the brand colour and is
// mirrored by the AccentColor asset, which is what keeps the sign-in mark and
// the icon the same red instead of the system blue the app used to inherit.
let deepCrimson = RGB(r: 74, g: 12, b: 24)
let crimson = RGB(r: 214, g: 40, b: 57)
let coral = RGB(r: 247, g: 96, b: 92)

// MARK: - Drawing

/// - Parameters:
///   - inset: fraction of the canvas to leave as margin (macOS wants ~10%).
///   - cornerFraction: corner radius as a fraction of the drawn square, 0 for
///     a full-bleed square that the system will mask itself.
func drawIcon(
    size: CGFloat,
    inset: CGFloat = 0,
    cornerFraction: CGFloat = 0,
    transparentBackground: Bool = false
) -> CGImage? {
    let alphaInfo: CGImageAlphaInfo = transparentBackground ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alphaInfo.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)

    let margin = size * inset
    let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = plate.width * cornerFraction

    // Background plate
    context.saveGState()
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    context.addPath(platePath)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [deepCrimson.cg(), crimson.cg(), coral.cg()] as CFArray,
        locations: [0.0, 0.62, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    context.restoreGState()

    drawFrames(in: context, plate: plate)

    return context.makeImage()
}

/// The mark itself, so the tvOS layer stack can draw it without a background.
func drawFrames(in context: CGContext, plate: CGRect) {
    let unit = plate.width / 1024

    // Back frame: smaller, offset up-right, translucent — depth without a
    // second competing shape at small sizes.
    let backSide = 360 * unit
    let back = CGRect(
        x: plate.midX - backSide / 2 + 88 * unit,
        y: plate.midY - backSide / 2 + 92 * unit,
        width: backSide,
        height: backSide
    )
    context.saveGState()
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45))
    context.setLineWidth(38 * unit)
    context.addPath(CGPath(
        roundedRect: back, cornerWidth: 74 * unit, cornerHeight: 74 * unit, transform: nil
    ))
    context.strokePath()
    context.restoreGState()

    // Front frame: larger, offset down-left, solid.
    let frontSide = 470 * unit
    let front = CGRect(
        x: plate.midX - frontSide / 2 - 46 * unit,
        y: plate.midY - frontSide / 2 - 48 * unit,
        width: frontSide,
        height: frontSide
    )
    let frontPath = CGPath(
        roundedRect: front, cornerWidth: 104 * unit, cornerHeight: 104 * unit, transform: nil
    )

    // A faint pane so the front frame reads as glass rather than a hole.
    context.saveGState()
    context.addPath(frontPath)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(52 * unit)
    context.addPath(frontPath)
    context.strokePath()
    context.restoreGState()
}

/// Mark only, transparent background — the tvOS parallax stack needs each layer
/// separately so the focus engine can shift them independently.
func drawMarkLayer(width: CGFloat, height: CGFloat) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setAllowsAntialiasing(true)
    let side = min(width, height)
    let plate = CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
    drawFrames(in: context, plate: plate)
    return context.makeImage()
}

func drawGradientLayer(width: CGFloat, height: CGFloat) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [deepCrimson.cg(), crimson.cg(), coral.cg()] as CFArray,
        locations: [0.0, 0.62, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: width, y: 0),
        options: []
    )
    return context.makeImage()
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        print("  ✗ could not create \(url.lastPathComponent)")
        return
    }
    CGImageDestinationAddImage(destination, image, nil)
    if CGImageDestinationFinalize(destination) {
        let hasAlpha = image.alphaInfo != .none
            && image.alphaInfo != .noneSkipLast
            && image.alphaInfo != .noneSkipFirst
        print("  ✓ \(url.lastPathComponent)  \(image.width)×\(image.height)"
              + (hasAlpha ? "  (alpha)" : "  (no alpha)"))
    }
}

let arguments = CommandLine.arguments
let outputDirectory = URL(
    fileURLWithPath: arguments.count > 1 ? arguments[1] : "Design/Icon",
    isDirectory: true
)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

print("FrameStation icon → \(outputDirectory.path)")

// iOS / iPadOS: full bleed, square, no alpha. The system masks it.
if let image = drawIcon(size: 1024) {
    write(image, to: outputDirectory.appendingPathComponent("AppIcon-iOS-1024.png"))
}

// macOS: pre-rounded with margin, per the HIG.
if let image = drawIcon(size: 1024, inset: 0.10, cornerFraction: 0.225) {
    write(image, to: outputDirectory.appendingPathComponent("AppIcon-macOS-1024.png"))
}

// tvOS parallax stack: back-to-front, each layer its own transparent image.
if let image = drawGradientLayer(width: 800, height: 480) {
    write(image, to: outputDirectory.appendingPathComponent("tvOS-Layer1-Background.png"))
}
if let image = drawMarkLayer(width: 800, height: 480) {
    write(image, to: outputDirectory.appendingPathComponent("tvOS-Layer2-Frames.png"))
}
if let image = drawGradientLayer(width: 3840, height: 1440) {
    write(image, to: outputDirectory.appendingPathComponent("tvOS-TopShelf-3840x1440.png"))
}

// Legibility proofs — check the mark still reads at Settings-row size.
for size in [180, 120, 87, 80, 60, 40] {
    if let image = drawIcon(size: CGFloat(size)) {
        write(image, to: outputDirectory.appendingPathComponent("preview-\(size).png"))
    }
}

print("done")

// MARK: - Install into the asset catalogs
//
// The whole reason this section exists: the generator used to stop at
// Design/Icon and somebody copied the results into the catalogs by hand. The
// app builds from the catalogs, so the day that copy was forgotten the phone
// kept showing the old icon while every other surface had the new one — which
// is exactly what happened. Writing both from one run is the only way this
// stays consistent.

/// macOS ships every size explicitly rather than letting the system downscale.
let macOSSizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let appRoot = outputDirectory
    .deletingLastPathComponent()   // Design
    .deletingLastPathComponent()   // repo root
    .appendingPathComponent("App/Resources", isDirectory: true)

// iOS: one full-bleed 1024, masked by the system.
if let image = drawIcon(size: 1024) {
    write(image, to: appRoot.appendingPathComponent(
        "iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    ))
}

// macOS: pre-rounded with margin, at every size the catalog declares.
for entry in macOSSizes {
    if let image = drawIcon(size: entry.pixels, inset: 0.10, cornerFraction: 0.225) {
        write(image, to: appRoot.appendingPathComponent(
            "macOS/Assets.xcassets/AppIcon.appiconset/\(entry.name).png"
        ))
    }
}

print("installed into asset catalogs")
