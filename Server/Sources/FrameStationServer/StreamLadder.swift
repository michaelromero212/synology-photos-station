import Foundation
import Vapor

/// What a phone plays away from home: every video in a few sizes, cut into
/// one-second pieces, with a playlist naming them all.
///
/// The player picks a size piece by piece from what the connection actually
/// delivers — 1080p when it can, down to 270p when it can't — instead of being
/// handed one file and stalling when the link is slower than the file. This is
/// how Apple's Photos plays from iCloud.
///
/// It replaced a single 1080p rendition. Measured on the NAS in October 2026,
/// those ran a median 6 Mbps and a quarter of them over 10, two to four times
/// the 720p copies Synology Photos streams (2.6 Mbps at 15 fps, 5.4 at 30). A
/// cellular connection that carried Synology's comfortably left ours at 0:00:
/// through a 5 Mbps link with a 150 ms round trip, the 1080p file stalled 13
/// times in 25 seconds, and this ladder not once, even at 3 Mbps.
///
/// One-second pieces, not Apple's six: a player won't start until it holds a
/// piece or two, so short ones start sooner — 2.3 s to the first frame through
/// that 3 Mbps link, against 3.5 s for two-second pieces.
///
/// Stored as HLS with one fragmented MP4 per size, which the playlists address
/// by byte range: four files and five playlists a video, not thousands of
/// segment files.
enum StreamLadder {
    /// The `derivation_jobs.kind` that builds one.
    static let jobKind = "ladder"

    /// The folder it lands in, inside the asset's derivative folder. Versioned,
    /// so a change to how ladders are cut can build new ones beside the old.
    static let directoryName = "stream-v1"
    static let masterName = "master.m3u8"

    /// Clips leaner than this already play away from home as they are, and a
    /// ladder would only add copies of something that was never the problem.
    static let bitrateThreshold = 2_500_000

    /// How long each piece is, and so how often every size has a keyframe.
    static let segmentSeconds = 1

    /// A size starts playback if its average fits under this. The first size a
    /// playlist lists is the one a player starts on; starting on the biggest
    /// was 1.3 s slower through a 3 Mbps link than starting near 2 Mbps and
    /// stepping up.
    static let startingBitrate = 2_000_000

    /// One size of the ladder.
    struct Rung: Equatable, Sendable {
        /// The playlist and media file it is written to: `v720.m3u8`, `v720.m4s`.
        let name: String
        /// Fits inside a square this many pixels on a side, so portrait and
        /// landscape get the same number of pixels.
        let longEdge: Int
        /// The most it may spend on any second of video, in bits per second.
        /// Quality-targeted below that (`crf`), so a quiet scene costs less.
        let maxrate: Int
    }

    /// The sizes, largest first. Caps from Apple's HLS ladder for the sizes
    /// above, and under Synology's 5.4 Mbps 720p: a phone screen at arm's
    /// length shows little between the two.
    static let rungs: [Rung] = [
        Rung(name: "v1080", longEdge: 1920, maxrate: 8_000_000),
        Rung(name: "v720", longEdge: 1280, maxrate: 4_000_000),
        Rung(name: "v432", longEdge: 768, maxrate: 1_500_000),
        Rung(name: "v270", longEdge: 480, maxrate: 600_000),
    ]

    /// The sizes a source gets: none larger than the source itself, and one at
    /// the source's own size when it falls well between two of them. Fewer
    /// than two means there is nothing to choose between, and no ladder.
    static func plan(sourceLongEdge: Int?) -> [Rung] {
        guard let longEdge = sourceLongEdge, longEdge > 0 else { return rungs }
        var planned = rungs.filter { $0.longEdge <= longEdge }
        // A 1000-pixel clip would otherwise top out at 768, throwing away a
        // quarter of its width for nothing.
        if let larger = rungs.last(where: { $0.longEdge > longEdge }),
           Double(planned.first?.longEdge ?? 0) < Double(longEdge) * 0.9 {
            planned.insert(
                Rung(name: larger.name, longEdge: longEdge, maxrate: larger.maxrate), at: 0
            )
        }
        return planned.count >= 2 ? planned : []
    }

    // MARK: - Frame rate

    /// A frame rate as the exact fraction ffmpeg reads and writes, so 59.94
    /// stays 60000/1001 and halving it lands on the same frames.
    struct FrameRate: Equatable, Sendable {
        let numerator: Int
        let denominator: Int

        var value: Double { Double(numerator) / Double(denominator) }
        var filter: String { "\(numerator)/\(denominator)" }

        func divided(by divisor: Int) -> FrameRate {
            FrameRate(numerator: numerator, denominator: denominator * divisor)
        }

        static let thirty = FrameRate(numerator: 30, denominator: 1)

        /// ffprobe's "60000/1001", or nil for "0/0" and anything unreadable.
        static func parse(_ text: String) -> FrameRate? {
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
            guard let numerator = parts.first.flatMap({ Int($0) }), numerator > 0 else { return nil }
            let denominator = parts.count > 1 ? Int(parts[1]) ?? 0 : 1
            guard denominator > 0 else { return nil }
            return FrameRate(numerator: numerator, denominator: denominator)
        }

        /// The rate a camera meant, for a rate a file only nearly states: a
        /// clip that dropped frames in low light averages 29.3, and cut at
        /// that it would land between the frames of every other size.
        static let standards: [FrameRate] = [
            FrameRate(numerator: 24000, denominator: 1001), FrameRate(numerator: 24, denominator: 1),
            FrameRate(numerator: 25, denominator: 1), FrameRate(numerator: 30000, denominator: 1001),
            FrameRate(numerator: 30, denominator: 1), FrameRate(numerator: 50, denominator: 1),
            FrameRate(numerator: 60000, denominator: 1001), FrameRate(numerator: 60, denominator: 1),
            FrameRate(numerator: 120, denominator: 1), FrameRate(numerator: 240, denominator: 1),
        ]

        func snapped() -> FrameRate {
            Self.standards.min { abs($0.value - value) < abs($1.value - value) }
                .flatMap { abs($0.value - value) < value * 0.03 ? $0 : nil } ?? self
        }
    }

    /// The rates a ladder is cut at: the largest size at the source's own rate
    /// up to 60, the rest at half of that when it is over 30.
    ///
    /// Sixty frames a second is the reason to film at 60, so the largest size
    /// keeps it; the small ones are what a weak link falls back to, and there
    /// twice the frames would each get half the bits. Halved exactly, so every
    /// frame of a small size is also a frame of the large one, and their
    /// keyframes — every `segmentSeconds` — fall at the same instants. Pieces
    /// that start at the same instant in every size are what let a player
    /// change size between two of them without a glitch.
    static func rates(source: FrameRate?) -> (top: FrameRate, rest: FrameRate) {
        guard let source = source?.snapped() else { return (.thirty, .thirty) }
        var top = source
        if top.value > 60.5 { top = top.divided(by: Int((top.value / 60).rounded(.up))) }
        let rest = top.value > 30.5 ? top.divided(by: 2) : top
        return (top, rest)
    }

    /// Frames between keyframes at each rate: one piece's worth at the smaller
    /// rate, and exactly that many times two at the larger, so both land on
    /// the same instants.
    static func keyframeIntervals(top: FrameRate, rest: FrameRate) -> (top: Int, rest: Int) {
        let restInterval = max(1, Int((rest.value * Double(segmentSeconds)).rounded()))
        let ratio = max(1, Int((top.value / rest.value).rounded()))
        return (restInterval * ratio, restInterval)
    }

    // MARK: - Building

    enum Audio: Equatable {
        case none
        /// An MP4 piece carries AAC as it is.
        case copy
        /// Anything else — an iPhone Live Photo's uncompressed PCM, say — is
        /// encoded once.
        case encode
    }

    static func directory(sha256: String, store: BlobStore) -> URL {
        store.derivativeDirectory(sha256: sha256).appendingPathComponent(directoryName)
    }

    static func exists(sha256: String, store: BlobStore) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(sha256: sha256, store: store).appendingPathComponent(masterName).path
        )
    }

    /// The names a link may ask for. Anything else is refused before it gets
    /// near the file system, so no path can climb out of the ladder's folder.
    static func isServable(_ file: String) -> Bool {
        if file == masterName { return true }
        let parts = file.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "m3u8" || parts[1] == "m4s" else { return false }
        return rungs.contains { $0.name == parts[0] }
    }

    static func contentType(for file: String) -> String {
        file.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"
    }

    /// Builds a video's ladder. Idempotent, like `Derivatives.makePreview`.
    ///
    /// Returns nil when the clip doesn't need one: lean enough already, or too
    /// small for more than one size.
    ///
    /// **Decoded once.** Every size comes out of a single ffmpeg, split after
    /// the decode, because decoding a 4K original is most of the work on this
    /// processor and doing it four times would be most of the work four times.
    static func make(
        blob: URL,
        sha256: String,
        sourceBitrate: Int?,
        sourceLongEdge: Int?,
        sourceDurationMS: Int?,
        store: BlobStore,
        logger: Logger
    ) async throws -> URL? {
        if let sourceBitrate, sourceBitrate < bitrateThreshold { return nil }
        let planned = plan(sourceLongEdge: sourceLongEdge)
        guard !planned.isEmpty else { return nil }

        let destination = directory(sha256: sha256, store: store)
        if exists(sha256: sha256, store: store) { return destination }

        // Written beside, then moved into place whole, so a transcode that is
        // killed part-way — the container restarting, the NAS rebooting —
        // can't leave a folder that looks finished.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(directoryName + ".partial")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: partial) }

        let rates = rates(source: await frameRate(blob))
        let audio: Audio
        switch await Derivatives.audioCodec(blob) {
        case nil: audio = .none
        case "aac": audio = .copy
        default: audio = .encode
        }

        logger.info("derive \(sha256.prefix(8)): stream ladder \(planned.map(\.name).joined(separator: " "))")
        let transcode = arguments(
            source: blob, rungs: planned, rates: rates, audio: audio, into: partial
        )
        let timeout = max(3600, Double(sourceDurationMS ?? 0) / 1000 * 30)
        // Held to two cores where it can be, like the rendition before it: a
        // thumbnail is always more urgent than this.
        if let processors = Derivatives.transcodeProcessors, let ffmpeg = Shell.resolve("ffmpeg") {
            try await Shell.runChecked("taskset", ["-c", processors, ffmpeg.path] + transcode, timeout: timeout)
        } else {
            try await Shell.runChecked("ffmpeg", transcode, timeout: timeout)
        }

        // Every size read back before the playlist naming them is written: a
        // file that exists is not the same as one that plays (see
        // `Derivatives.makePlaybackRendition`).
        var built: [Built] = []
        for rung in planned {
            let playlist = partial.appendingPathComponent(rung.name + ".m3u8")
            let media = partial.appendingPathComponent(rung.name + ".m4s")
            guard let written = try? String(contentsOf: playlist, encoding: .utf8),
                  let pieces = MediaPlaylist(written), !pieces.durations.isEmpty,
                  let probe = await probe(media)
            else { throw DerivativeError.ladderFailed(blob.lastPathComponent) }
            try normalized(written, name: rung.name)
                .write(to: playlist, atomically: true, encoding: .utf8)
            built.append(Built(rung: rung, pieces: pieces, probe: probe))
        }
        // Pieces that don't start at the same instants in every size would
        // make a player stumble each time it changed size. Built to line up;
        // checked, because it is the whole point.
        let counts = Set(built.map(\.pieces.durations.count))
        guard counts.count == 1 else {
            throw DerivativeError.ladderMisaligned(
                blob.lastPathComponent, built.map { "\($0.rung.name) \($0.pieces.durations.count)" }
            )
        }

        try masterPlaylist(built.map(\.variant))
            .write(to: partial.appendingPathComponent(masterName), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// The ffmpeg command for a ladder: one input, decoded once, one HLS output
    /// per size.
    static func arguments(
        source: URL, rungs planned: [Rung], rates: (top: FrameRate, rest: FrameRate),
        audio: Audio, into directory: URL
    ) -> [String] {
        let intervals = keyframeIntervals(top: rates.top, rest: rates.rest)
        // Constant frame rate first, at the largest size's rate, so every size
        // counts its keyframes off the same frames. A phone's own variable
        // rate would otherwise put them a frame apart.
        let labels = planned.indices.map { "[s\($0)]" }.joined()
        var graph = "[0:v:0]fps=\(rates.top.filter),split=\(planned.count)\(labels)"
        for (index, rung) in planned.enumerated() {
            let halved = index > 0 && rates.rest != rates.top
            graph += ";[s\(index)]" + (halved ? "fps=\(rates.rest.filter)," : "")
                + "scale=\(rung.longEdge):\(rung.longEdge)"
                + ":force_original_aspect_ratio=decrease:force_divisible_by=2[o\(index)]"
        }

        var command = [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            // Before the input, the decoder's threads; see `Derivatives.playbackThreads`.
            "-threads", String(Derivatives.playbackThreads), "-i", source.path,
            "-filter_complex", graph,
        ]
        for (index, rung) in planned.enumerated() {
            let interval = index == 0 ? intervals.top : intervals.rest
            command += ["-map", "[o\(index)]"]
            // The first audio track only: an iPhone clip also carries spatial
            // audio and metadata tracks this ffmpeg can't decode or doesn't
            // need. See `Derivatives.makePlaybackRendition`.
            if audio != .none { command += ["-map", "0:a:0"] }
            command += [
                "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high",
                "-crf", "23", "-maxrate", String(rung.maxrate),
                // A one-second buffer, so no one-second piece can run far
                // over the cap the playlist promises.
                "-bufsize", String(rung.maxrate),
                "-pix_fmt", "yuv420p",
                // A keyframe exactly every piece and nowhere else, which is
                // what makes every size's pieces start together.
                "-g", String(interval), "-keyint_min", String(interval), "-sc_threshold", "0",
                "-threads", String(Derivatives.playbackThreads),
            ]
            switch audio {
            case .none: break
            case .copy: command += ["-c:a", "copy"]
            case .encode: command += ["-c:a", "aac", "-b:a", "192k"]
            }
            command += [
                "-f", "hls",
                // Shorter than a piece, so every keyframe starts one.
                "-hls_time", "0.5",
                "-hls_playlist_type", "vod",
                "-hls_segment_type", "fmp4",
                "-hls_flags", "single_file+independent_segments",
                "-hls_segment_filename", directory.appendingPathComponent(rung.name + ".m4s").path,
                directory.appendingPathComponent(rung.name + ".m3u8").path,
            ]
        }
        return command
    }

    // MARK: - Playlists

    /// One size's pieces, as its playlist lists them.
    struct MediaPlaylist: Equatable {
        let durations: [Double]
        let byteCounts: [Int]

        init?(_ text: String) {
            guard text.contains("#EXT-X-ENDLIST") else { return nil }
            var durations: [Double] = []
            var byteCounts: [Int] = []
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("#EXTINF:") {
                    let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first
                    guard let seconds = value.flatMap({ Double($0) }) else { return nil }
                    durations.append(seconds)
                } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                    let value = line.dropFirst("#EXT-X-BYTERANGE:".count).split(separator: "@").first
                    guard let bytes = value.flatMap({ Int($0) }) else { return nil }
                    byteCounts.append(bytes)
                }
            }
            guard durations.count == byteCounts.count else { return nil }
            self.durations = durations
            self.byteCounts = byteCounts
        }

        /// What a playlist calls BANDWIDTH: the fastest any one piece needs the
        /// link to be.
        var peakBitrate: Int {
            zip(durations, byteCounts)
                .map { duration, bytes in duration > 0 ? Double(bytes) * 8 / duration : 0 }
                .max().map { Int($0.rounded(.up)) } ?? 0
        }

        var averageBitrate: Int {
            let seconds = durations.reduce(0, +)
            guard seconds > 0 else { return 0 }
            return Int((Double(byteCounts.reduce(0, +)) * 8 / seconds).rounded(.up))
        }
    }

    /// A size as the top-level playlist describes it to a player choosing one.
    struct Variant: Equatable {
        let name: String
        let width: Int
        let height: Int
        let frameRate: Double
        let codecs: String
        let peakBitrate: Int
        let averageBitrate: Int
    }

    /// The playlist a player opens first: every size, with what each needs from
    /// the link.
    ///
    /// Written here rather than by ffmpeg, so the numbers are the ones measured
    /// off the pieces actually written, and so the first size listed — the one
    /// a player starts on — can be chosen. The largest that averages under
    /// `startingBitrate` goes first, then the rest largest first.
    static func masterPlaylist(_ variants: [Variant]) -> String {
        let start = variants.first { $0.averageBitrate <= startingBitrate } ?? variants.last
        let ordered = start.map { start in [start] + variants.filter { $0 != start } } ?? variants
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for variant in ordered {
            lines.append(
                "#EXT-X-STREAM-INF:BANDWIDTH=\(variant.peakBitrate)"
                    + ",AVERAGE-BANDWIDTH=\(variant.averageBitrate)"
                    + ",CODECS=\"\(variant.codecs)\""
                    + ",RESOLUTION=\(variant.width)x\(variant.height)"
                    + String(format: ",FRAME-RATE=%.3f", variant.frameRate)
            )
            lines.append(variant.name + ".m3u8")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct Built {
        let rung: Rung
        let pieces: MediaPlaylist
        let probe: Probe

        var variant: Variant {
            Variant(
                name: rung.name, width: probe.width, height: probe.height,
                frameRate: probe.frameRate, codecs: probe.codecs,
                peakBitrate: pieces.peakBitrate, averageBitrate: pieces.averageBitrate
            )
        }
    }

    // MARK: - Probing

    /// What a playlist has to say about a size, read off the file itself.
    struct Probe: Equatable {
        let width: Int
        let height: Int
        let frameRate: Double
        /// RFC 6381, as `CODECS` takes it: "avc1.64002a,mp4a.40.2".
        let codecs: String
    }

    private struct ProbeOutput: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let profile: String?
            let level: Int?
            let width: Int?
            let height: Int?
            let avg_frame_rate: String?
        }
        let streams: [Stream]
    }

    static func probe(_ file: URL) async -> Probe? {
        guard let output = try? await Shell.run(
            "ffprobe",
            ["-v", "error", "-show_entries",
             "stream=codec_type,codec_name,profile,level,width,height,avg_frame_rate",
             "-of", "json", file.path],
            timeout: 120
        ), let parsed = try? JSONDecoder().decode(ProbeOutput.self, from: output.stdout)
        else { return nil }
        guard let video = parsed.streams.first(where: { $0.codec_type == "video" }),
              video.codec_name == "h264", let width = video.width, let height = video.height,
              let level = video.level
        else { return nil }
        var codecs = [avcCodec(profile: video.profile, level: level)]
        if let audio = parsed.streams.first(where: { $0.codec_type == "audio" }) {
            codecs.append(aacCodec(profile: audio.profile))
        }
        return Probe(
            width: width, height: height,
            frameRate: video.avg_frame_rate.flatMap(FrameRate.parse)?.value ?? 30,
            codecs: codecs.joined(separator: ",")
        )
    }

    /// "avc1." and the profile, its constraints and the level as hex, which is
    /// how a player tells from the playlist alone whether it can decode a size.
    static func avcCodec(profile: String?, level: Int) -> String {
        let (idc, constraints): (Int, Int)
        switch profile {
        case "Main": (idc, constraints) = (77, 0x40)
        case "Baseline": (idc, constraints) = (66, 0x00)
        case "Constrained Baseline": (idc, constraints) = (66, 0x40)
        default: (idc, constraints) = (100, 0x00)
        }
        return String(format: "avc1.%02x%02x%02x", idc, constraints, level)
    }

    static func aacCodec(profile: String?) -> String {
        switch profile {
        case "HE-AAC": return "mp4a.40.5"
        case "HE-AACv2": return "mp4a.40.29"
        default: return "mp4a.40.2"
        }
    }

    /// The source's frame rate: its average, which `rates` snaps to the rate
    /// the camera meant. Not `r_frame_rate`, which for a phone's variable-rate
    /// clip can be the timescale's 240 or 600 and would double every frame.
    static func frameRate(_ file: URL) async -> FrameRate? {
        struct Output: Decodable {
            struct Stream: Decodable {
                let avg_frame_rate: String?
                let r_frame_rate: String?
            }
            let streams: [Stream]
        }
        guard let output = try? await Shell.run(
            "ffprobe",
            ["-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=avg_frame_rate,r_frame_rate", "-of", "json", file.path],
            timeout: 120
        ), let stream = (try? JSONDecoder().decode(Output.self, from: output.stdout))?.streams.first
        else { return nil }
        return stream.avg_frame_rate.flatMap(FrameRate.parse)
            ?? stream.r_frame_rate.flatMap(FrameRate.parse)
    }

    /// A size's playlist naming its media file the way the top-level playlist
    /// is served beside it: by name alone. ffmpeg writes the name it was given
    /// for the file, and this one was given a path into a folder that is about
    /// to be renamed.
    static func normalized(_ playlist: String, name: String) -> String {
        let media = name + ".m4s"
        return playlist.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if line.hasPrefix("#EXT-X-MAP:"), let start = line.range(of: "URI=\""),
               let end = line[start.upperBound...].firstIndex(of: "\"") {
                return line[..<start.upperBound] + media + line[end...]
            }
            if !line.isEmpty, !line.hasPrefix("#"), line.hasSuffix("/" + media) || line == media {
                return Substring(media)
            }
            return line
        }.joined(separator: "\n")
    }
}
