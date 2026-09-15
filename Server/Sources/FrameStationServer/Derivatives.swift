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

    /// Bumped when thumbnail *output* changes, so already-generated derivatives
    /// can be told apart from current ones and regenerated once (and the client
    /// cache-busts to them — see `TimelineItem.thumbVersion`).
    /// v1: sized by the short edge (was the longest), so a square grid tile
    /// never upscales an odd-aspect image into a blur.
    /// v2: an unsharp mask after the downscale, so detailed content (screenshots,
    /// text, UI) reads crisp in a small tile instead of soft — the step Apple
    /// and Synology use to make a grid look premium. See migration 0022.
    static let thumbnailVersion = 2

    /// The widest aspect a thumbnail is sized for. Past this a panorama would
    /// turn into an enormous strip for no gain — the square grid only ever shows
    /// its centre — so the short edge is allowed to fall a little below target.
    static let maxThumbnailAspect = 3.0

    /// Unsharp-mask parameters for the post-downscale sharpen, as vips `sharpen`
    /// takes them. Downscaling always softens, most visibly on hard edges and
    /// text; this restores the crispness. Conservative on purpose — too much and
    /// edges halo — and gathered here because it is the dial to tune by eye.
    /// `sigma` is the radius, `m1` the gain in flat areas (0 so noise isn't
    /// amplified), `m2` the gain on edges (the real sharpening).
    static let sharpenSigma = 0.8
    static let sharpenFlatGain = 0.0
    static let sharpenEdgeGain = 2.0

    /// Thumbnails are JPEG rather than HEIC: encoding HEIC needs an x265
    /// encoder in the container that JPEG does not. Sharpened edges want a
    /// higher quality than a plain photo would — Q82 leaves mosquito noise
    /// around text — so thumbnails encode at Q90; the 2048 preview stays at 82.
    private static let jpegSuffix = "[Q=82,strip,optimize_coding]"
    private static let thumbnailJPEG = "[Q=90,strip,optimize_coding]"

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

            // Two steps, one JPEG encode: resize to a lossless intermediate,
            // then sharpen straight into the final JPEG. Sharpening the encoded
            // thumbnail instead would re-compress it; going through `.v` keeps
            // the only lossy step the final write.
            let intermediate = directory.appendingPathComponent("thumb-\(size).v")
            defer { try? FileManager.default.removeItem(at: intermediate) }
            try await Shell.runChecked(
                "vips",
                ["thumbnail", imageSource.path, intermediate.path,
                 String(longest), "--size", "down"],
                timeout: 120
            )
            try await Shell.runChecked(
                "vips",
                ["sharpen", intermediate.path, destination.path + thumbnailJPEG,
                 "--sigma", String(sharpenSigma),
                 "--m1", String(sharpenFlatGain),
                 "--m2", String(sharpenEdgeGain)],
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

    // MARK: - Playback rendition

    /// The long edge of the cellular rendition, and the file it lands in.
    ///
    /// 1080p rather than the 720p Synology settles on. Theirs has to decode in a
    /// Windows browser, so it targets the lowest common denominator; every
    /// client here is an Apple device, and on a phone screen the difference
    /// between 720p and 1080p is the difference between "watchable" and "looks
    /// like the video I took".
    static let playbackLongEdge = 1920
    static let playbackName = "playback-1080.mp4"

    /// The `derivation_jobs.kind` that builds one.
    static let playbackJobKind = "playback"

    /// Only clips fatter than this get one. A video already at a sane bitrate
    /// streams fine on cellular, and transcoding it would cost CPU and storage
    /// to produce something no better than the original.
    static let playbackBitrateThreshold = 12_000_000

    /// Builds the cellular rendition. Idempotent, like `makePreview`.
    ///
    /// Returns nil when the original is already lean enough to stream as-is —
    /// the caller then serves the original and nothing is generated.
    ///
    /// **Audio is stream-copied, not re-encoded.** It is about 0.2 Mbps of a
    /// 51 Mbps clip, so degrading it would save nothing measurable and cost the
    /// one thing a memory can't spare: the voices sounding like they did. The
    /// rendition is therefore bit-identical to the original in everything you
    /// hear, and only the picture is reduced.
    static func makePlaybackRendition(
        blob: URL,
        sha256: String,
        sourceBitrate: Int?,
        sourceLongEdge: Int?,
        store: BlobStore,
        logger: Logger
    ) async throws -> URL? {
        if let sourceBitrate, sourceBitrate < playbackBitrateThreshold { return nil }

        let directory = store.derivativeDirectory(sha256: sha256)
        let destination = directory.appendingPathComponent(playbackName)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Self-healing: one built before the check above existed may be
            // unplayable, and returning it would serve the same broken file for
            // ever. Throwing it away costs a transcode and fixes it for good.
            if try await hasVideoStream(destination) { return destination }
            logger.warning("playback rendition for \(sha256.prefix(8)) is unplayable; rebuilding")
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Written to a temporary name and moved into place, so a transcode that
        // is killed part-way (the container restarting, the NAS rebooting)
        // cannot leave a truncated file that looks finished to the check above.
        let partial = directory.appendingPathComponent(playbackName + ".partial")
        defer { try? FileManager.default.removeItem(at: partial) }

        // Scaled only when the source is actually bigger. Deciding here, from a
        // dimension we already store, rather than with an `if(gt(iw,ih),…)`
        // expression inside the filter: ffmpeg is exec'd with an argument array
        // and never sees a shell, so the quotes such an expression needs would
        // arrive as literal characters, and the commas inside it read as filter
        // separators. `force_original_aspect_ratio=decrease` fits the clip
        // inside the box in either orientation with no expression at all, and
        // `force_divisible_by=2` keeps both dimensions even, which H.264 needs.
        let needsScaling = sourceLongEdge.map { $0 > playbackLongEdge } ?? true
        let scaling = needsScaling
            ? ["-vf", "scale=\(playbackLongEdge):\(playbackLongEdge)"
                    + ":force_original_aspect_ratio=decrease:force_divisible_by=2"]
            : []

        logger.info("derive \(sha256.prefix(8)): playback rendition")
        try await Shell.runChecked(
            "ffmpeg",
            [
                "-y", "-i", blob.path,
                // One video track and one audio track, named explicitly rather
                // than left to ffmpeg's default selection. An iPhone clip also
                // carries a spatial-audio `apac` track this ffmpeg cannot decode
                // and several `mebx` metadata tracks, none of which belong in a
                // playback rendition. The `?` makes audio optional so a silent
                // clip still transcodes instead of failing.
                "-map", "0:v:0", "-map", "0:a:0?",
            ] + scaling + [
                // H.264 rather than HEVC: this box has no hardware encoder wired
                // up yet, and libx265 in software on a J4125 is not a thing you
                // wait for. `veryfast` is the difference between minutes and
                // tens of minutes per clip.
                "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high",
                // Quality-targeted, with a ceiling so a busy scene can't spike
                // past what a cellular link will carry.
                "-crf", "23", "-maxrate", "10M", "-bufsize", "20M",
                "-pix_fmt", "yuv420p",
                // Frame rate is inherited, not forced. Synology's proxy drops to
                // 15fps and it shows — a child running looks like a flipbook.
                "-c:a", "copy",
                // Moves the index to the front so playback can start before the
                // whole file has been fetched. Without it AVPlayer must read the
                // end of the file first, which is a wasted round trip.
                "-movflags", "+faststart",
                // Named explicitly because the output is written to `.partial`
                // and ffmpeg picks its muxer from the file extension. Without
                // this it fails before doing any work — "Unable to find a
                // suitable output format" — which is precisely how the first
                // version of this shipped.
                "-f", "mp4",
                partial.path,
            ],
            timeout: 3600
        )

        // Existing is not the same as usable.
        //
        // A rendition once arrived 112 MB with a duration and no readable track
        // at all — `+faststart` rewrites the file in a second pass to move the
        // index to the front, and a pass that does not finish leaves the bytes
        // without the index. ffmpeg had exited, the file was there, the job was
        // marked done, and the client got "video could not be played". So the
        // output is probed before it is allowed into place; a failure here
        // leaves the job failed, and the heal will try again.
        guard FileManager.default.fileExists(atPath: partial.path),
              try await hasVideoStream(partial) else {
            throw DerivativeError.renditionFailed(blob.lastPathComponent)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// Whether a file has a video track ffmpeg can actually read.
    ///
    /// `ffprobe` rather than a size check: the failure this exists to catch
    /// produced a large file with a plausible duration and no streams in it.
    private static func hasVideoStream(_ file: URL) async throws -> Bool {
        let output = try? await Shell.run(
            "ffprobe",
            ["-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=codec_type", "-of", "csv=p=0", file.path],
            timeout: 120
        )
        return output?.stdoutText.contains("video") == true
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
    case renditionFailed(String)
    case malformedPPM(String)

    var description: String {
        switch self {
        case .posterFailed(let name):
            return "Could not extract a poster frame from \(name)."
        case .renditionFailed(let name):
            return "Could not build a playback rendition for \(name)."
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
