import FrameStationAPI
import Foundation
import Vapor

/// Thumbnail and placeholder generation via `libvips`, plus video poster frames
/// via `ffmpeg`.
///
/// Sizes follow ARCHITECTURE.md §3: **256 and 512 eagerly** (~7 GB across the
/// library), **2048 lazily** on first full-screen view (up to ~40 GB, which is
/// what would otherwise turn the initial import from an overnight job into a
/// multi-day one).
enum Derivatives {
    static let eagerSizes = [256, 512]
    static let previewSize = 2048

    /// Bumped when the thumbnail *sizing* changes, so already-generated
    /// derivatives can be told apart from current ones and regenerated once.
    /// v1: sized by the short edge (was the longest), so a square grid tile
    /// never upscales an odd-aspect image into a blur. See migration 0022.
    static let thumbnailVersion = 1

    /// The widest aspect a thumbnail is sized for. Past this a panorama would
    /// turn into an enormous strip for no gain — the square grid only ever shows
    /// its centre — so the short edge is allowed to fall a little below target.
    static let maxThumbnailAspect = 3.0

    /// Thumbnails are JPEG rather than HEIC: encoding HEIC needs an x265
    /// encoder in the container that JPEG does not, and at 256 px the size
    /// saving is a few KB per asset. Decoding HEIC *input* still works — that's
    /// libheif, which vips has.
    private static let jpegSuffix = "[Q=82,strip,optimize_coding]"

    struct Output {
        var thumbHash: [UInt8]?
        var width: Int?
        var height: Int?
    }

    /// Builds the eager derivative set and the ThumbHash placeholder.
    static func generate(
        blob: URL,
        sha256: String,
        mediaType: MediaType,
        store: BlobStore,
        logger: Logger
    ) async throws -> Output {
        let directory = store.derivativeDirectory(sha256: sha256)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Videos can't be handed to vips directly; render a poster frame first
        // and treat that as the image source for everything downstream.
        let imageSource: URL
        if mediaType == .video {
            let poster = directory.appendingPathComponent("poster.jpg")
            try await extractPoster(from: blob, to: poster)
            imageSource = poster
        } else {
            imageSource = blob
        }

        var output = Output()

        // The ≤100 px render comes first now: it is both the ThumbHash input and
        // where the aspect ratio comes from, and the eager thumbnails need that
        // ratio to size by the short edge.
        logger.debug("derive \(sha256.prefix(8)): thumbhash render")
        let placeholder = directory.appendingPathComponent("thumbhash.ppm")
        defer { try? FileManager.default.removeItem(at: placeholder) }
        try await Shell.runChecked(
            "vips",
            ["thumbnail", imageSource.path, placeholder.path, "100", "--size", "down"],
            timeout: 120
        )

        // Long edge over short edge, ≥ 1. Defaults to 1 — the old fit-the-box
        // behaviour — if the render can't be read, so a decode failure degrades
        // to a square fit rather than sizing wrong.
        var aspect = 1.0
        logger.debug("derive \(sha256.prefix(8)): encoding thumbhash")
        if let image = try? PPM.read(placeholder) {
            output.thumbHash = ThumbHash.encode(
                width: image.width, height: image.height, rgba: image.rgba
            )
            output.width = image.width
            output.height = image.height
            aspect = Double(max(image.width, image.height))
                / Double(max(min(image.width, image.height), 1))
        } else {
            logger.warning("could not read placeholder render for \(sha256)")
        }

        // Sized by the SHORT edge. vips fits the *longest* edge into the number
        // it is given, so passing `size × aspect` lands the short edge on `size`
        // — enough to fill a square grid tile without upscaling, whatever the
        // shape. Capped so a panorama doesn't become a giant strip.
        let ratio = min(aspect, maxThumbnailAspect)
        for size in eagerSizes {
            logger.debug("derive \(sha256.prefix(8)): thumb-\(size)")
            let destination = directory.appendingPathComponent("thumb-\(size).jpg")
            let longest = Int((Double(size) * ratio).rounded())
            try await Shell.runChecked(
                "vips",
                ["thumbnail", imageSource.path, destination.path + jpegSuffix,
                 String(longest), "--size", "down"],
                timeout: 120
            )
        }

        return output
    }

    /// Renders `preview-2048.jpg` on demand. Idempotent.
    static func makePreview(
        blob: URL,
        sha256: String,
        mediaType: MediaType,
        store: BlobStore
    ) async throws -> URL {
        let directory = store.derivativeDirectory(sha256: sha256)
        let destination = directory.appendingPathComponent("preview-\(previewSize).jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source: URL
        if mediaType == .video {
            let poster = directory.appendingPathComponent("poster.jpg")
            if !FileManager.default.fileExists(atPath: poster.path) {
                try await extractPoster(from: blob, to: poster)
            }
            source = poster
        } else {
            source = blob
        }

        try await Shell.runChecked(
            "vips",
            ["thumbnail", source.path, destination.path + jpegSuffix,
             String(previewSize), "--size", "down"],
            timeout: 180
        )
        return destination
    }

    /// Seeks a little way in before grabbing the frame — the first frame of a
    /// phone video is very often black or mid-autoexposure.
    private static func extractPoster(from video: URL, to destination: URL) async throws {
        let seek = "00:00:01"
        do {
            try await Shell.runChecked(
                "ffmpeg",
                ["-y", "-ss", seek, "-i", video.path, "-frames:v", "1",
                 "-q:v", "3", destination.path],
                timeout: 180
            )
        } catch {
            // Clip shorter than the seek point; fall back to the first frame.
            try await Shell.runChecked(
                "ffmpeg",
                ["-y", "-i", video.path, "-frames:v", "1", "-q:v", "3", destination.path],
                timeout: 180
            )
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw DerivativeError.posterFailed(video.lastPathComponent)
        }
    }

    static func missingTools() -> [String] {
        ["vips", "exiftool", "ffmpeg", "ffprobe"].filter { !Shell.isAvailable($0) }
    }
}

enum DerivativeError: Error, CustomStringConvertible {
    case posterFailed(String)
    case malformedPPM(String)

    var description: String {
        switch self {
        case .posterFailed(let name):
            return "Could not extract a poster frame from \(name)."
        case .malformedPPM(let reason):
            return "Malformed PPM: \(reason)"
        }
    }
}

/// Minimal binary PPM (P6) reader.
///
/// This is how pixels get from vips into `ThumbHash` without linking an image
/// library: `ImageIO` is Apple-only and the server runs on Linux, so vips
/// renders to P6 and we parse the few bytes of header ourselves.
enum PPM {
    struct Image {
        let width: Int
        let height: Int
        /// Row-major RGBA8, alpha forced opaque.
        let rgba: [UInt8]
    }

    static func read(_ url: URL) throws -> Image {
        let data = try Data(contentsOf: url)
        guard data.count > 2, data[0] == UInt8(ascii: "P"), data[1] == UInt8(ascii: "6") else {
            throw DerivativeError.malformedPPM("not a P6 file")
        }

        // Header tokens are whitespace-separated and may be interleaved with
        // `#` comments — vips writes one ("#vips2ppm - <date>").
        var index = 2
        var tokens: [Int] = []

        while tokens.count < 3, index < data.count {
            let byte = data[index]
            if byte == UInt8(ascii: "#") {
                while index < data.count, data[index] != UInt8(ascii: "\n") { index += 1 }
                continue
            }
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
                continue
            }
            var value = 0
            var sawDigit = false
            while index < data.count, data[index] >= UInt8(ascii: "0"), data[index] <= UInt8(ascii: "9") {
                value = value * 10 + Int(data[index] - UInt8(ascii: "0"))
                index += 1
                sawDigit = true
            }
            guard sawDigit else {
                throw DerivativeError.malformedPPM("unexpected byte in header")
            }
            tokens.append(value)
        }

        guard tokens.count == 3 else {
            throw DerivativeError.malformedPPM("truncated header")
        }
        let (width, height, maxValue) = (tokens[0], tokens[1], tokens[2])
        guard width > 0, height > 0, maxValue == 255 else {
            throw DerivativeError.malformedPPM("unsupported dimensions or depth \(maxValue)")
        }

        // Exactly one whitespace byte separates the header from the raster.
        index += 1
        let expected = width * height * 3
        guard data.count - index >= expected else {
            throw DerivativeError.malformedPPM(
                "expected \(expected) pixel bytes, found \(data.count - index)"
            )
        }

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self)
            for pixel in 0..<(width * height) {
                rgba[pixel * 4] = base[pixel * 3]
                rgba[pixel * 4 + 1] = base[pixel * 3 + 1]
                rgba[pixel * 4 + 2] = base[pixel * 3 + 2]
            }
        }

        return Image(width: width, height: height, rgba: rgba)
    }
}
