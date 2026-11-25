import Foundation
import Vapor

/// HDR video away from home: what a clip was recorded in, and what this
/// machine can encode it with. (Its poster, made SDR for the grid, is in
/// `Derivatives`.)
///
/// Every iPhone since the 12 records HDR — 10-bit HEVC, HLG — and the stream
/// ladder used to make 8-bit H.264 of it. The HLG tags came through, so it
/// wasn't washed out, but 8 bits of HLG band across a sky, and the Dolby
/// Vision layer was lost. An HDR clip's ladder is now 10-bit HEVC with the
/// clip's own range, which is what Photos streams from iCloud.
///
/// Measured on the J4125 in November 2026, 10 s of a 1080p HDR clip: today's
/// H.264 took 18.6 s, 10-bit HEVC in software 34.3 s, and on the processor's
/// own encoder — through Intel's non-free media driver — 14.6 s. Without that
/// driver the hardware only decodes HEVC. So the encoder is the hardware one or
/// nothing: where it's missing, an HDR clip gets today's ladder rather than one
/// that ties up the NAS for twice as long.
enum HDRVideo {
    /// What a clip's picture was recorded in.
    enum Range: String, Sendable {
        case sdr
        /// Hybrid log-gamma: every iPhone HDR clip, and Dolby Vision 8.4's base.
        case hlg
        /// Perceptual quantizer: HDR10 and most cameras that aren't phones.
        case pq

        var isHDR: Bool { self != .sdr }

        /// ffmpeg's name for the transfer, written into what it encodes.
        var transfer: String {
            switch self {
            case .sdr: return "bt709"
            case .hlg: return "arib-std-b67"
            case .pq: return "smpte2084"
            }
        }

        /// What a playlist's VIDEO-RANGE says, so a player that can't show HDR
        /// knows before it asks for a piece.
        var playlistValue: String {
            switch self {
            case .sdr: return "SDR"
            case .hlg: return "HLG"
            case .pq: return "PQ"
            }
        }

        /// What `assets.dynamic_range` records, as photos already do.
        var recorded: String { isHDR ? "hdr" : "standard" }

        /// From ffprobe's name for a stream's transfer. Anything else, or
        /// none, is SDR.
        init(transfer: String?) {
            switch transfer {
            case "arib-std-b67": self = .hlg
            case "smpte2084": self = .pq
            default: self = .sdr
            }
        }
    }

    /// The range, read off the first video stream's transfer. A clip ffprobe
    /// can't read is treated as SDR: today's ladder plays everywhere.
    static func range(_ file: URL) async -> Range {
        struct Output: Decodable {
            struct Stream: Decodable { let color_transfer: String? }
            let streams: [Stream]
        }
        guard let output = try? await Shell.run(
            "ffprobe",
            ["-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=color_transfer", "-of", "json", file.path],
            timeout: 120
        ), let stream = (try? JSONDecoder().decode(Output.self, from: output.stdout))?.streams.first
        else { return .sdr }
        return Range(transfer: stream.color_transfer)
    }

    /// What a poster needs to know of a clip's picture to turn it into SDR:
    /// its range, and the colors it's tagged with, in the names zscale takes.
    struct Signal: Sendable, Equatable {
        var range: Range
        var primaries: String
        var matrix: String
        var isFullRange: Bool

        static let sdr = Signal(range: .sdr, primaries: "bt709", matrix: "bt709", isFullRange: false)
    }

    /// The range and colors, read off the first video stream in one ffprobe,
    /// the range as `range(_:)` reads it. A tag that's missing, or one a phone
    /// doesn't record HDR in, reads as what every iPhone records: BT.2020
    /// colors and limited range. (Only an HDR clip's colors are ever used.)
    static func signal(_ file: URL) async -> Signal {
        struct Output: Decodable {
            struct Stream: Decodable {
                let color_transfer: String?
                let color_primaries: String?
                let color_space: String?
                let color_range: String?
            }
            let streams: [Stream]
        }
        guard let output = try? await Shell.run(
            "ffprobe",
            ["-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=color_transfer,color_primaries,color_space,color_range",
             "-of", "json", file.path],
            timeout: 120
        ), let stream = (try? JSONDecoder().decode(Output.self, from: output.stdout))?.streams.first
        else { return .sdr }
        func known(_ value: String?, in names: [String], else fallback: String) -> String {
            value.flatMap { names.contains($0) ? $0 : nil } ?? fallback
        }
        return Signal(
            range: Range(transfer: stream.color_transfer),
            primaries: known(stream.color_primaries, in: ["bt709", "bt2020"], else: "bt2020"),
            matrix: known(stream.color_space, in: ["bt709", "bt2020nc", "bt2020c"], else: "bt2020nc"),
            isFullRange: stream.color_range == "pc"
        )
    }

    /// How an HDR ladder is encoded here.
    enum Encoder: String, Sendable {
        /// The Intel processor's encoder, through VA-API. The NAS.
        case vaapi
        /// Apple's, on a Mac running the dev stack.
        case videotoolbox
    }

    /// The render node VA-API opens, passed into the container from the host.
    static let renderNode = "/dev/dri/renderD128"

    /// Which encoder this machine has, checked once by encoding a tenth of a
    /// second of test pattern exactly as a ladder would. Nil when none works,
    /// and HDR clips then get today's ladder.
    ///
    /// `FRAMESTATION_HDR_ENCODER` overrides it: `off` to turn HDR ladders off,
    /// `vaapi` or `videotoolbox` to name one without the check.
    static func encoder() async -> Encoder? {
        await Detection.shared.encoder()
    }

    private actor Detection {
        static let shared = Detection()
        private var result: Encoder??

        func encoder() async -> Encoder? {
            if let result { return result }
            let found = await detect()
            result = .some(found)
            return found
        }

        private func detect() async -> Encoder? {
            switch Environment.get("FRAMESTATION_HDR_ENCODER") {
            case "off": return nil
            case "vaapi": return .vaapi
            case "videotoolbox": return .videotoolbox
            default: break
            }
            #if os(macOS)
            let candidates: [Encoder] = [.videotoolbox]
            #else
            guard FileManager.default.fileExists(atPath: renderNode) else { return nil }
            let candidates: [Encoder] = [.vaapi]
            #endif
            for candidate in candidates where await works(candidate) { return candidate }
            return nil
        }

        private func works(_ encoder: Encoder) async -> Bool {
            let rung = StreamLadder.Rung(name: "probe", longEdge: 256, maxrate: 1_000_000)
            let arguments = ["-y", "-nostdin", "-hide_banner", "-loglevel", "error"]
                + HDRVideo.inputArguments(for: encoder)
                + ["-f", "lavfi", "-i", "testsrc2=duration=0.1:size=256x144:rate=30",
                   "-vf", "format=p010le" + HDRVideo.uploadFilter(for: encoder)]
                + HDRVideo.encodeArguments(
                    for: encoder, rung: rung, range: .hlg, keyframeInterval: 3
                )
                + ["-f", "null", "-"]
            return (try? await Shell.runChecked("ffmpeg", arguments, timeout: 30)) != nil
        }
    }

    // MARK: - ffmpeg arguments

    /// Before the input: the device the upload filter hands frames to.
    static func inputArguments(for encoder: Encoder) -> [String] {
        switch encoder {
        case .vaapi:
            return ["-init_hw_device", "vaapi=va:\(renderNode)", "-filter_hw_device", "va"]
        case .videotoolbox:
            return []
        }
    }

    /// Appended to a size's filter chain, after it is scaled and turned 10-bit.
    static func uploadFilter(for encoder: Encoder) -> String {
        encoder == .vaapi ? ",hwupload" : ""
    }

    /// One size's encoder settings.
    ///
    /// The average aims at 60% of the size's cap and the cap is the same one
    /// H.264 had: HEVC holds the same picture in about a third fewer bits, so
    /// what was spent on keeping up is now spent on detail. A keyframe exactly
    /// every piece and every one an IDR, which is what lets a player start or
    /// change size at any piece. No B-frames, so the keyframes stay on the
    /// frames the other sizes put theirs on.
    static func encodeArguments(
        for encoder: Encoder, rung: StreamLadder.Rung, range: Range, keyframeInterval: Int
    ) -> [String] {
        let average = String(rung.maxrate * 6 / 10)
        var arguments: [String]
        switch encoder {
        case .vaapi:
            arguments = [
                "-c:v", "hevc_vaapi", "-profile:v", "main10",
                "-rc_mode", "VBR", "-b:v", average,
                "-maxrate", String(rung.maxrate), "-bufsize", String(rung.maxrate),
                // `idr_interval` counts the I-frames *between* IDRs: 0 makes
                // every one an IDR. At 1, the NAS cut 2-second pieces from a
                // 1-second keyframe interval (measured 11-16, 5 pieces for 8.9 s).
                "-g", String(keyframeInterval), "-idr_interval", "0", "-bf", "0",
            ]
        case .videotoolbox:
            arguments = [
                "-c:v", "hevc_videotoolbox", "-profile:v", "main10",
                "-b:v", average, "-maxrate", String(rung.maxrate),
                "-g", String(keyframeInterval), "-bf", "0",
            ]
        }
        // Said outright: an encoder handed uploaded frames doesn't always carry
        // the source's tags through, and untagged 10-bit plays as SDR.
        arguments += [
            "-color_primaries", "bt2020", "-color_trc", range.transfer, "-colorspace", "bt2020nc",
            // What Apple's players require of HEVC in an MP4.
            "-tag:v", "hvc1",
        ]
        return arguments
    }
}
