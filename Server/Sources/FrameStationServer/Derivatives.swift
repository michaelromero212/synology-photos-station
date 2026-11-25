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
    /// v5: an HDR clip's poster is tone-mapped to SDR, where it came out gray
    /// and flat. See `toneMapFilter`. Only HDR posters changed, so a poster
    /// written the plain way is still v4's and keeps that number: see
    /// `plainVideoThumbnailVersion`.
    static let videoThumbnailVersion = 5

    /// The version of a video thumbnail whose poster was written the plain
    /// way: every SDR clip's, and an HDR clip's where tone mapping failed.
    /// Nothing about those changed in v5, so they stay at 4. An SDR clip is
    /// then never rebuilt for v5, nor its thumbnail fetched again by every
    /// device for the same picture, and an HDR clip written plain still reads
    /// as not converted, to be made again (see
    /// `MetadataBackfill.enqueueMissingThumbnails`).
    static let plainVideoThumbnailVersion = 4

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
        /// What these thumbnails are, for `assets.thumb_version`: the photo
        /// version, or for a video whichever its poster came out as.
        var version: Int
        /// A video's range, read for its poster and recorded with it. Nil for
        /// a photo, whose range comes with its metadata.
        var range: HDRVideo.Range?
        /// Why an HDR clip's poster was written the plain way, kept beside
        /// its job. Nil when it wasn't.
        var posterNote: String?
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
        var output = Output(version: thumbnailVersion)
        if mediaType == .video {
            let poster = directory.appendingPathComponent("poster.jpg")
            // Read every time a poster is made, so every video has its range
            // on record: what tells the boot pass which posters still want
            // tone mapping, and what the Information panel shows.
            let signal = await HDRVideo.signal(blob)
            let made = try await extractPoster(
                from: blob, to: poster, signal: signal, logger: logger
            )
            output.range = signal.range
            output.version = made.isToneMapped ? videoThumbnailVersion : plainVideoThumbnailVersion
            if made.isToneMapped {
                logger.info("derive \(sha256.prefix(8)): \(signal.range.playlistValue) poster tone-mapped")
            } else if let problem = made.problem {
                output.posterNote = "HDR poster not tone-mapped: \(problem)"
                logger.warning("""
                    derive \(sha256.prefix(8)): \(signal.range.playlistValue) poster not \
                    tone-mapped, written as before: \(problem)
                    """)
            }
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
                try await extractPoster(from: blob, to: poster, signal: await HDRVideo.signal(blob))
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

    // MARK: - Transcodes

    /// The single 1080p cellular rendition clips had before stream ladders.
    ///
    /// None are built any more (`StreamLadder` replaced them), but the ones
    /// already on disk are still what a clip without a ladder plays away from
    /// home: `AssetController.playbackURL` hands one out while it exists, and
    /// the original once it doesn't. A clip's goes when its ladder is built
    /// (see `StreamLadder.retireRendition`).
    static let playbackName = "playback-1080.mp4"

    /// How many of the processor's cores a transcode may use: two of the
    /// J4125's four. Left to choose, ffmpeg takes all four for a 4K clip.
    /// Nobody is waiting on a ladder, and somebody is always waiting on a
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

    /// The codec of a file's first audio track, nil when it has none.
    static func audioCodec(_ file: URL) async -> String? {
        let output = try? await Shell.run(
            "ffprobe",
            ["-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=codec_name", "-of", "csv=p=0", file.path],
            timeout: 120
        )
        let codec = output?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return codec.isEmpty ? nil : codec
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
    ///
    /// An HDR clip's frame is tone-mapped to SDR on its way to the JPEG (see
    /// `toneMapFilter`). Where that can't be done, or ffmpeg fails at it, the
    /// frame is written the plain way after all, so no clip is ever left
    /// without a poster, and the result says it wasn't tone-mapped, so the
    /// clip isn't counted as converted.
    @discardableResult
    static func extractPoster(
        from video: URL, to destination: URL, signal: HDRVideo.Signal, logger: Logger? = nil
    ) async throws -> Poster {
        let chosen = await posterTime(for: video)
        if let chosen, chosen != posterBaseline, let logger {
            logger.info("""
                derive \(video.deletingPathExtension().lastPathComponent.prefix(8)): \
                poster from \(chosen)s
                """)
        }

        // The chosen frame, else one second in as before, else the very first
        // frame, which every clip has.
        let times = [chosen ?? posterBaseline, nil]

        var poster = Poster()
        if signal.range.isHDR {
            if let problem = await toneMapProblem() {
                poster.problem = problem
            } else {
                let filter = toneMapFilter(for: signal)
                var failure = "no frame came out"
                for time in times {
                    guard let problem = await writeFrame(of: video, at: time, to: destination, filter: filter)
                    else { return Poster(isToneMapped: true) }
                    failure = problem
                }
                poster.problem = "ffmpeg failed to tone-map it: \(failure)"
            }
        }
        for time in times {
            if await writeFrame(of: video, at: time, to: destination, filter: nil) == nil { return poster }
        }
        throw DerivativeError.posterFailed(video.lastPathComponent)
    }

    /// What `extractPoster` wrote.
    struct Poster {
        /// Tone-mapped from HDR, rather than written the plain way.
        var isToneMapped = false
        /// Why an HDR clip's poster wasn't tone-mapped. Nil for an SDR clip,
        /// which never is.
        var problem: String?
    }

    /// Writes one frame of `video` to `destination`: the frame at `time`, or
    /// the first. Nil once it's written, otherwise what went wrong.
    ///
    /// Without a filter, exactly the command posters always had, so an SDR
    /// clip's poster comes out the same bytes it always did.
    private static func writeFrame(
        of video: URL, at time: Double?, to destination: URL, filter: String?
    ) async -> String? {
        try? FileManager.default.removeItem(at: destination)
        let seek = time.map { ["-ss", String(format: "%.3f", $0)] } ?? []
        // Errors only when filtering, so what ffmpeg says on failing is the
        // reason rather than its banner.
        let arguments = (filter == nil ? ["-y"] : ["-y", "-v", "error"])
            + seek + ["-i", video.path, "-frames:v", "1"]
            + (filter.map { ["-vf", $0] } ?? [])
            + ["-q:v", "3", destination.path]
        do {
            try await Shell.runChecked("ffmpeg", arguments, timeout: 180)
        } catch {
            return reason(error)
        }
        // Not just present: a seek past the end can leave an empty file.
        let size = (try? FileManager.default.attributesOfItem(
            atPath: destination.path
        ))?[.size] as? NSNumber
        guard let size, size.int64Value > 0 else { return "an empty file" }
        return nil
    }

    /// The first thing ffmpeg said, which with `-v error` is why it stopped,
    /// without the filter's address it starts with.
    private static func reason(_ error: Error) -> String {
        guard case ShellError.failed(_, let status, let stderr) = error else {
            return String(describing: error)
        }
        let first = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let said = first
            .replacingOccurrences(of: #"^\[[^\]]*\] *"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return said.isEmpty ? "ffmpeg exited \(status)" : String(said.prefix(200))
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

    // MARK: - HDR posters

    /// HDR reference white in nits, per ITU-R BT.2408: where an HLG camera
    /// puts a white shirt or a page (75% of its signal), and what an SDR
    /// poster's white stands for.
    static let posterReferenceWhite = 203.0

    /// The brightest an HDR poster's highlights are kept apart up to, in nits:
    /// HLG's nominal peak, and what most PQ video is mastered to.
    static let posterHDRPeak = 1000.0

    /// Where the tone curve starts to bend, as a fraction of SDR white.
    static let posterKnee = 0.6

    /// The ffmpeg filters that make an HDR frame its SDR poster.
    ///
    /// An iPhone records HLG: a signal for a bright HDR screen, with reference
    /// white at 75% and the rest of the range left for highlights. Written to a
    /// JPEG as it was, that 75% is a light gray, and BT.2020's colors read as
    /// BT.709's come out pale: the poster was gray and flat. These turn it into
    /// the picture Photos shows on an SDR screen.
    ///
    /// 1. Scaled to fit `previewSize`, the largest anything is made from the
    ///    poster, before any of it is in floating point. At 4K each stage is
    ///    about 100 MB and four times the work, on a J4125 running four lanes.
    /// 2. To linear light, with the clip's transfer, colors, matrix and range
    ///    said outright, and the colors said again for the frame it hands on.
    ///    ffmpeg 4.4's zscale otherwise takes them from the frame, and stops
    ///    with "no path between colorspaces" when a frame doesn't carry them.
    ///    `npl` set to reference white makes that white 1.0, SDR's white, so
    ///    everything below it lands about where SDR video puts it: 18% gray at
    ///    39% (SDR has it at 41%), a face at 65% HLG at 77%.
    /// 3. BT.2020's colors to BT.709's, which sRGB shares.
    /// 4. `mobius` leaves everything up to `posterKnee` of white exactly as it
    ///    is, shadows, faces and mid-tones, and rolls off smoothly above it,
    ///    so highlights up to HDR's peak fit under SDR white rather than
    ///    clipping: white lands at 91%, twice as bright at 97%, the peak at
    ///    100%. `desat=0`, as the default fades every highlight's color. The
    ///    usual chain, `npl=100` with `hable`, leaves white at 76%: the same
    ///    gray the untoned poster had, only in the right colors.
    /// 5. To sRGB, which is what a JPEG with no profile is read as, and left as
    ///    RGB, so ffmpeg makes the JPEG's YCbCr itself, by JPEG's own (BT.601)
    ///    numbers. Handed video's BT.709 YCbCr instead, a JPEG reader shifts
    ///    every color a little.
    ///
    /// Server/Dockerfile runs this chain for an iPhone clip's tags and fails
    /// the image if white and gray don't come out where they should.
    static func toneMapFilter(for signal: HDRVideo.Signal) -> String {
        let side = previewSize
        let range = signal.isFullRange ? "full" : "limited"
        let peak = String(format: "%.3f", posterHDRPeak / posterReferenceWhite)
        return [
            "scale=w='if(gte(iw,ih),min(\(side),trunc(iw/2)*2),-2)'"
                + ":h='if(gte(iw,ih),-2,min(\(side),trunc(ih/2)*2))':flags=lanczos",
            "zscale=tin=\(signal.range.transfer):pin=\(signal.primaries):min=\(signal.matrix)"
                + ":rin=\(range):t=linear:p=\(signal.primaries):npl=\(Int(posterReferenceWhite))",
            "format=gbrpf32le",
            "zscale=p=bt709",
            "tonemap=tonemap=mobius:param=\(posterKnee):desat=0:peak=\(peak)",
            "zscale=t=iec61966-2-1:d=error_diffusion",
            "format=gbrp",
        ].joined(separator: ",")
    }

    /// Nil when this machine can tone-map an HDR poster, otherwise why not.
    /// Checked once, by putting a frame of 10-bit test pattern through
    /// `toneMapFilter` into a JPEG, as a poster is written. Homebrew's ffmpeg
    /// has no zscale, so on a Mac every HDR clip gets the plain poster.
    ///
    /// `FRAMESTATION_HDR_POSTERS` overrides it: `off` to write every poster
    /// the plain way, `on` to tone-map without the check.
    static func toneMapProblem() async -> String? {
        await ToneMapCheck.shared.problem()
    }

    private actor ToneMapCheck {
        static let shared = ToneMapCheck()
        private var result: String??

        func problem() async -> String? {
            if let result { return result }
            let found = await check()
            result = .some(found)
            return found
        }

        private func check() async -> String? {
            switch Environment.get("FRAMESTATION_HDR_POSTERS") {
            case "off": return "turned off by FRAMESTATION_HDR_POSTERS"
            case "on": return nil
            default: break
            }
            let probe = FileManager.default.temporaryDirectory
                .appendingPathComponent("tone-map-check-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: probe) }
            let iPhone = HDRVideo.Signal(
                range: .hlg, primaries: "bt2020", matrix: "bt2020nc", isFullRange: false
            )
            do {
                try await Shell.runChecked(
                    "ffmpeg",
                    ["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=256x144:rate=1:duration=1",
                     "-frames:v", "1", "-vf", "format=yuv420p10le," + Derivatives.toneMapFilter(for: iPhone),
                     "-q:v", "3", probe.path],
                    timeout: 60
                )
            } catch {
                return "this ffmpeg can't tone-map (\(Derivatives.reason(error)))"
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: probe.path))?[.size] as? NSNumber
            return (size?.int64Value ?? 0) > 0 ? nil : "this ffmpeg can't tone-map (it wrote nothing)"
        }
    }

    static func missingTools() -> [String] {
        ["vips", "exiftool", "ffmpeg", "ffprobe"].filter { !Shell.isAvailable($0) }
    }
}

enum DerivativeError: Error, CustomStringConvertible {
    case posterFailed(String)
    case ladderFailed(String)
    case ladderMisaligned(String, [String])
    case malformedPPM(String)

    var description: String {
        switch self {
        case .posterFailed(let name):
            return "Could not extract a poster frame from \(name)."
        case .ladderFailed(let name):
            return "Could not build the stream ladder for \(name)."
        case .ladderMisaligned(let name, let counts):
            return "The stream ladder for \(name) came out with sizes cut differently: "
                + counts.joined(separator: ", ") + " pieces."
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
