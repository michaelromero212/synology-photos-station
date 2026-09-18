#if os(macOS)
import AVFoundation
import AppKit
import CoreGraphics
import FrameStationAPI
import FrameStationKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders the thumbnail a Mac hands over with an upload.
///
/// The iPhone renders its from `PHAsset`, which is both easier and better —
/// PhotoKit already holds a thumbnail for everything in the library. A Mac has
/// only the file that was dropped on it, so this does the same job from bytes:
/// ImageIO for a picture, one frame for a video.
///
/// Why it is worth doing at all: without it, anything dragged in from the Mac
/// is a gray tile on every phone in the house until the NAS works through its
/// derivation queue. The handover exists precisely so nobody waits for that,
/// and a photo library where the fast path depends on *which device* put the
/// photo in is not a fast path, it is a coincidence.
enum FileThumbnail {

    /// A grid-sized JPEG and its ThumbHash, or nil if the file cannot be read
    /// as an image — which is not an error, only the absence of a shortcut.
    static func render(file: URL, mediaType: MediaType) -> (jpeg: Data, thumbHash: Data?)? {
        let pixels = PhotoGridMetrics.thumbnailPixels
        guard let cgImage = image(from: file, mediaType: mediaType, maxPixels: pixels)
        else { return nil }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = bitmap.representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]
        ), jpeg.count <= UploadThumbnailRequest.maxBytes else { return nil }

        return (jpeg, thumbHash(of: cgImage))
    }

    private static func image(
        from file: URL, mediaType: MediaType, maxPixels: Int
    ) -> CGImage? {
        switch mediaType {
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            // A frame a moment in, not the very first: videos routinely open on
            // a black or half-exposed frame, and a black square is a worse
            // stand-in than no thumbnail at all.
            let at = CMTime(seconds: 1, preferredTimescale: 600)
            return try? generator.copyCGImage(at: at, actualTime: nil)

        case .photo:
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            // `ThumbnailFromImageIfAbsent` so a file with no embedded thumbnail
            // still produces one, rather than silently returning nothing.
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        }
    }

    /// The same 32-pixel impression the iPhone sends. See `AssetUploader`.
    private static func thumbHash(of cgImage: CGImage) -> Data? {
        let longest = CGFloat(max(cgImage.width, cgImage.height))
        guard longest > 0 else { return nil }
        let scale = min(32 / longest, 1)
        let width = max(Int((CGFloat(cgImage.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(cgImage.height) * scale).rounded()), 1)

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Data(ThumbHash.encode(width: width, height: height, rgba: rgba))
    }
}
#endif
