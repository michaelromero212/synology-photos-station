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

/// Gradient and mark together, for the wide banner an Apple TV shows above the
/// app grid.
///
/// Not the layer stack: the top shelf is one flat image, and it is very wide —
/// 1920×720 up to 4640×1440 — so `drawMarkLayer`'s "fill the short edge" rule
/// would put a mark the full height of the banner, which reads as a logo
/// shouting rather than a home screen. `markHeight` keeps it to a fraction of
/// the height, centred, with the gradient carrying the rest.
func drawBanner(width: CGFloat, height: CGFloat, markHeight: CGFloat = 0.52) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

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

    let side = height * markHeight
    let plate = CGRect(
        x: (width - side) / 2, y: (height - side) / 2, width: side, height: side
    )
    drawFrames(in: context, plate: plate)
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

// macOS: pre-rounded with margin, per the HIG — and *transparent* outside the
// plate.
//
// `transparentBackground` existed from the start and was never passed here, so
// every macOS size shipped as a black square with a red plate painted on it.
// In the Dock that reads as a dark tile among icons that float, which is what
// "looks weird" turned out to be. iOS is the opposite case and still opts out:
// full bleed, no alpha, masked by the system.
if let image = drawIcon(
    size: 1024, inset: 0.10, cornerFraction: 0.225, transparentBackground: true
) {
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

// macOS: pre-rounded with margin, at every size the catalog declares, each one
// transparent outside the plate.
for entry in macOSSizes {
    if let image = drawIcon(
        size: entry.pixels, inset: 0.10, cornerFraction: 0.225, transparentBackground: true
    ) {
        write(image, to: appRoot.appendingPathComponent(
            "macOS/Assets.xcassets/AppIcon.appiconset/\(entry.name).png"
        ))
    }
}

// tvOS: the brand assets, which are the reason a tvOS build can be uploaded at
// all. Without an "App Icon & Top Shelf Image" collection `actool` warns and the
// App Store refuses the build — and for a long time this script drew the layers
// into Design/Icon and stopped there, with no catalog for them to go into.
//
// The shapes are fixed by tvOS and are not guesses: the icon is 400×240 at 1x,
// the App Store copy of it is a single 1280×768, and the two top shelves are
// 1920×720 and 2320×720 at 1x. Each is a *layer stack* rather than a flat
// image, which is what lets the focus engine part the frames from their
// background as you move the remote across the row.
let tvBrand = appRoot.appendingPathComponent(
    "tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets", isDirectory: true
)

/// One layer stack: the gradient behind, the frames in front, at every scale
/// the catalog declares.
func writeStack(_ stack: String, sizes: [(suffix: String, width: CGFloat, height: CGFloat)]) {
    for size in sizes {
        if let image = drawGradientLayer(width: size.width, height: size.height) {
            write(image, to: tvBrand.appendingPathComponent(
                "\(stack)/Back.imagestacklayer/Content.imageset/Back\(size.suffix).png"
            ))
        }
        // Transparent outside the mark, or the front layer would hide the
        // background it is supposed to float above.
        if let image = drawMarkLayer(width: size.width, height: size.height) {
            write(image, to: tvBrand.appendingPathComponent(
                "\(stack)/Front.imagestacklayer/Content.imageset/Front\(size.suffix).png"
            ))
        }
    }
}

writeStack("App Icon.imagestack", sizes: [("", 400, 240), ("@2x", 800, 480)])
writeStack("App Icon - App Store.imagestack", sizes: [("", 1280, 768)])

for shelf in [
    (name: "TopShelf", width: CGFloat(1920), height: CGFloat(720)),
    (name: "TopShelfWide", width: CGFloat(2320), height: CGFloat(720)),
] {
    for scale in [(suffix: "", factor: CGFloat(1)), (suffix: "@2x", factor: CGFloat(2))] {
        if let image = drawBanner(
            width: shelf.width * scale.factor, height: shelf.height * scale.factor
        ) {
            let folder = shelf.name == "TopShelf"
                ? "Top Shelf Image.imageset" : "Top Shelf Image Wide.imageset"
            write(image, to: tvBrand.appendingPathComponent(
                "\(folder)/\(shelf.name)\(scale.suffix).png"
            ))
        }
    }
}

// The sign-in screen shows the icon itself rather than a second drawing of it.
// There used to be a SwiftUI re-creation here, and it was close but not the
// same — which is the whole problem: two drawings of one mark drift, and the
// difference shows up side by side the moment somebody taps the icon and lands
// on the sign-in screen.
for platform in ["iOS", "macOS", "tvOS"] {
    if let image = drawIcon(size: 1024) {
        write(image, to: appRoot.appendingPathComponent(
            "\(platform)/Assets.xcassets/AppMark.imageset/AppMark-1024.png"
        ))
    }
}

print("installed into asset catalogs")
