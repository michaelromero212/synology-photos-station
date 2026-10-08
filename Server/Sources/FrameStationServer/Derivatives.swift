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
    /// v3: converted to sRGB instead of having the color profile thrown away.
    /// See `exportProfile`.
    static let thumbnailVersion = 3

    /// The same, for videos, whose thumbnails come from a poster frame. It has
    /// its own number so a better poster rebuilds the videos and leaves every
    /// photo alone.
    /// v4: the poster is the sharpest of a few early frames, not whatever was
    /// on screen one second in. See `extractPoster`.
    static let videoThumbnailVersion = 4

    static func thumbnailVersion(for mediaType: MediaType) -> Int {
        mediaType == .video ? videoThumbnailVersion : thumbnailVersion
    }

    /// The widest aspect a thumbnail is sized for. Past this a panorama would
    /// turn into an enormous strip for no gain — the square grid only ever shows
    /// its center — so the short edge is allowed to fall a little below target.
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

    /// Converts to sRGB on the way down, which is the difference between a
    /// thumbnail that matches the photograph and one that doesn't.
    ///
    /// Every photograph an iPhone takes is Display P3. `vips thumbnail` does not
    /// color-manage unless asked: without this it resized the P3 numbers and
    /// copied the profile through, and then `strip` — which removes the ICC
    /// profile along with the EXIF — threw the profile away. What reached the
    /// grid was P3 pixel data in an untagged file, and an untagged file is read
    /// as sRGB. The same numbers mean *less* saturated colors in sRGB than in
    /// P3, so every thumbnail came out duller and a shade darker than the
    /// original, worst on exactly the colors people notice: foliage, a red
    /// jacket, a sunlit wall.
    ///
    /// Measured on a six-patch P3 target through this pipeline. Yellow
    /// (255, 214, 0) arrived as (248, 216, 73) — a blue channel of 73 where
    /// there should be none. Green (46, 140, 62) arrived as (73, 138, 70). With
    /// this flag every patch lands within two units of the original.
    ///
    /// Still stripped afterward, and that is correct rather than a compromise:
    /// the pixels really are sRGB now, and untagged means sRGB by convention, so
    /// dropping the profile costs nothing and keeps the file small.
    private static let exportProfile = ["--export-profile", "srgb"]

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
            try await extractPoster(from: blob, to: poster, logger: logger)
            imageSource = poster
            // The full-screen preview was rendered from the old poster, and
            // `makePreview` keeps whatever it finds. Removed, it's rebuilt
            // from the new one the next time someone opens the video.
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("preview-\(previewSize).jpg")
            )
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
            ["thumbnail", imageSource.path, placeholder.path, "100", "--size", "down"]
                + exportProfile,
            timeout: 120
        )

        // Long edge over short edge, ≥ 1. Defaults to 1 — the old fit-the-box
        // behavior — if the render can't be read, so a decode failure degrades
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
                 String(longest), "--size", "down"] + exportProfile,
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
             String(previewSize), "--size", "down"] + exportProfile,
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

    /// How many of the processor's cores a transcode may use: two of the
    /// J4125's four. Left to choose, ffmpeg takes all four for a 4K clip.
    /// Nobody is waiting on a rendition, and somebody is always waiting on a
    /// thumbnail.
    ///
    /// Also the decoder's thread count and the encoder's, but those alone
    /// don't hold it to two: the scaler and the pipeline between them start
    /// threads of their own, and on a Mac `-threads 2` for both still came to
    /// almost four cores. `transcodeProcessors` is what holds it.
    static let playbackThreads = 2

    /// The cores a transcode runs on: the last `playbackThreads` of those this
    /// server may use, as `taskset -c` takes them ("2,3" on a four-core NAS). Nil
    /// where `taskset` or the list isn't available (on a Mac, for one), or
    /// when there are no more cores than that anyway.
    static let transcodeProcessors: String? = {
        guard Shell.isAvailable("taskset"),
              let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
              let line = status.split(separator: "\n")
                  .first(where: { $0.hasPrefix("Cpus_allowed_list:") })
        else { return nil }
        let allowed = processorList(line.dropFirst("Cpus_allowed_list:".count))
        guard allowed.count > playbackThreads else { return nil }
        return allowed.suffix(playbackThreads).map(String.init).joined(separator: ",")
    }()

    /// A kernel CPU list, "0-2,5", as [0, 1, 2, 5].
    static func processorList(_ text: Substring) -> [Int] {
        text.split(separator: ",").flatMap { range -> [Int] in
            let ends = range.split(separator: "-")
                .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            switch ends.count {
            case 1: return ends
            case 2 where ends[0] <= ends[1]: return Array(ends[0]...ends[1])
            default: return []
            }
        }
    }

    /// How long a transcode may run: an hour, or 20 times the clip's length
    /// if that's longer. On two threads a long 4K clip can need more than an
    /// hour, and a limit it could never meet would fail it, retry it and fail
    /// it again, an hour of the processor each time.
    static func playbackTimeout(durationMS: Int?) -> TimeInterval {
        max(3600, Double(durationMS ?? 0) / 1000 * 20)
    }

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
        sourceDurationMS: Int?,
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
        let transcode: [String] = [
            // Before the input, this sets the decoder's threads; the one
            // after the encoder settings sets the encoder's.
            "-y", "-threads", String(playbackThreads), "-i", blob.path,
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
            "-threads", String(playbackThreads),
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
        ]
        // Held to its two cores where it can be. `taskset` execs ffmpeg in its
        // own place, as `nice` does, so a timeout still stops ffmpeg itself.
        if let processors = transcodeProcessors, let ffmpeg = Shell.resolve("ffmpeg") {
            try await Shell.runChecked(
                "taskset", ["-c", processors, ffmpeg.path] + transcode,
                timeout: playbackTimeout(durationMS: sourceDurationMS)
            )
        } else {
            try await Shell.runChecked(
                "ffmpeg", transcode, timeout: playbackTimeout(durationMS: sourceDurationMS)
            )
        }

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

    // MARK: - Poster frame

    /// Where in a video its thumbnail frame is looked for, in seconds.
    ///
    /// Only the opening seconds, so the thumbnail still shows how the video
    /// begins, as Apple's does. One second in is among them. It used to be
    /// the only frame looked at, and it stays the choice unless another is
    /// clearly sharper, so a poster that was fine doesn't change for nothing.
    static let posterCandidates: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]
    static let posterBaseline = 1.0

    /// How much sharper the sharpest frame may measure while another still
    /// counts as about as sharp. Real motion blur measures several times
    /// softer; this only keeps measurement noise from swapping one good frame
    /// for another.
    static let posterSharperBy = 1.25

    /// The side of the gray square each candidate is measured at. About the
    /// size a grid tile shows, so sharpness is judged at the scale anyone
    /// will see it, and finer blur that no tile would show doesn't count.
    private static let posterSampleSide = 384

    /// Picks and writes a video's poster: the sharpest of a few early frames
    /// that isn't black, blown out or blank.
    ///
    /// The first frame of a phone video is very often black or still
    /// adjusting its exposure, so the start was never used. A fixed second in
    /// is often mid-pan or mid-motion, though, and made a smeared grid tile.
    /// Measuring a handful costs a few seconds of background work per video.
    static func extractPoster(
        from video: URL, to destination: URL, logger: Logger? = nil
    ) async throws {
        let chosen = await posterTime(for: video)
        if let chosen, chosen != posterBaseline, let logger {
            logger.info("""
                derive \(video.deletingPathExtension().lastPathComponent.prefix(8)): \
                poster from \(chosen)s
                """)
        }

        // The chosen frame, else one second in as before, else the very first
        // frame, which every clip has.
        for time in [chosen ?? posterBaseline, nil] {
            try? FileManager.default.removeItem(at: destination)
            let seek = time.map { ["-ss", String(format: "%.3f", $0)] } ?? []
            let written = (try? await Shell.runChecked(
                "ffmpeg",
                ["-y"] + seek + ["-i", video.path, "-frames:v", "1", "-q:v", "3", destination.path],
                timeout: 180
            )) != nil
            // Not just present: a seek past the end can leave an empty file.
            let size = (try? FileManager.default.attributesOfItem(
                atPath: destination.path
            ))?[.size] as? NSNumber
            if written, let size, size.int64Value > 0 { return }
        }
        throw DerivativeError.posterFailed(video.lastPathComponent)
    }

    /// When to take the poster from, or nil if no frame could be measured.
    static func posterTime(for video: URL) async -> Double? {
        let length = await duration(of: video)
        var times = posterCandidates.filter { time in length.map { time < $0 - 0.1 } ?? true }
        // Too short for any of them: its start is all there is.
        if times.isEmpty { times = [0] }

        var samples: [FrameSample] = []
        for time in times {
            if let sample = await sample(video, at: time) { samples.append(sample) }
        }
        return choosePosterTime(samples)
    }

    /// Among the usable frames (every frame, if none is), those about as sharp
    /// as the sharpest: the one at `posterBaseline` if it's among them, since
    /// that's the poster it had before, and otherwise the earliest, to stay
    /// close to how the video starts.
    static func choosePosterTime(_ samples: [FrameSample]) -> Double? {
        let usable = samples.filter(\.isUsable)
        let pool = usable.isEmpty ? samples : usable
        guard let sharpest = pool.map(\.sharpness).max() else { return nil }
        let sharpEnough = pool.filter { $0.sharpness * posterSharperBy >= sharpest }
        if sharpEnough.contains(where: { $0.time == posterBaseline }) { return posterBaseline }
        return sharpEnough.min(by: { $0.time < $1.time })?.time
    }

    /// One candidate frame, measured.
    struct FrameSample {
        let time: Double
        /// Mean brightness, 0 to 255.
        let brightness: Double
        /// How far brightness strays from that mean. Near zero for a blank or
        /// solid frame.
        let contrast: Double
        /// Variance of the Laplacian: how much fine edge detail there is. A
        /// smeared or out-of-focus frame scores low, and so does a dim one.
        let sharpness: Double

        /// Not black, not blown out, not blank.
        var isUsable: Bool { brightness >= 24 && brightness <= 245 && contrast >= 6 }

        /// From a `side` × `side` grayscale image, one byte per pixel.
        init(time: Double, gray: [UInt8], side: Int) {
            self.time = time
            let count = Double(gray.count)
            var sum = 0.0, squares = 0.0
            for value in gray {
                let v = Double(value)
                sum += v
                squares += v * v
            }
            brightness = sum / count
            contrast = (max(squares / count - brightness * brightness, 0)).squareRoot()

            var lapSum = 0.0, lapSquares = 0.0, interior = 0.0
            if side > 2 {
                for y in 1..<(side - 1) {
                    for x in 1..<(side - 1) {
                        let i = y * side + x
                        let laplacian = 4 * Double(gray[i])
                            - Double(gray[i - 1]) - Double(gray[i + 1])
                            - Double(gray[i - side]) - Double(gray[i + side])
                        lapSum += laplacian
                        lapSquares += laplacian * laplacian
                        interior += 1
                    }
                }
            }
            let lapMean = interior > 0 ? lapSum / interior : 0
            sharpness = interior > 0 ? max(lapSquares / interior - lapMean * lapMean, 0) : 0
        }
    }

    /// The frame at `time`, squeezed to a small gray square and measured. Nil
    /// if there's no frame there.
    private static func sample(_ video: URL, at time: Double) async -> FrameSample? {
        let side = posterSampleSide
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("poster-sample-\(UUID().uuidString).gray")
        defer { try? FileManager.default.removeItem(at: raw) }
        // Squeezed to a square rather than kept in proportion. Every candidate
        // of a video is squeezed alike, so they still compare fairly, and the
        // byte count then says exactly how big the image is.
        guard (try? await Shell.runChecked(
            "ffmpeg",
            ["-y", "-v", "error", "-ss", String(format: "%.3f", time), "-i", video.path,
             "-frames:v", "1", "-vf", "scale=\(side):\(side):flags=area,format=gray",
             "-f", "rawvideo", raw.path],
            timeout: 120
        )) != nil,
              let data = try? Data(contentsOf: raw), data.count == side * side
        else { return nil }
        return FrameSample(time: time, gray: [UInt8](data), side: side)
    }

    /// A video's length in seconds, or nil if ffprobe can't tell.
    private static func duration(of video: URL) async -> Double? {
        guard let result = try? await Shell.run(
            "ffprobe",
            ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", video.path],
            timeout: 60
        ), result.status == 0 else { return nil }
        return Double(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
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
