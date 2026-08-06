import Foundation

/// The arithmetic behind the transport controls.
///
/// Separated from the player because every one of these has an edge that only
/// shows on real footage: a duration that is still `indefinite` while the first
/// bytes arrive, a skip that would land past the end, a clip long enough to need
/// an hours field. None of that needs an `AVPlayer` to test.
public enum VideoTiming {
    /// How far the skip controls jump, matching every Apple player.
    public static let skipInterval: Double = 10

    /// Where a skip should land, clamped to the clip.
    ///
    /// Skipping back from 4 seconds in lands at zero rather than refusing —
    /// "watch that bit again" from near the start means "start again", and a
    /// button that does nothing reads as broken.
    ///
    /// A duration of zero means it isn't known yet (a stream still loading), so
    /// the only bound that can be enforced is the start.
    public static func skipTarget(
        from current: Double, by delta: Double, duration: Double
    ) -> Double {
        guard current.isFinite, delta.isFinite else { return 0 }
        let target = current + delta
        guard duration.isFinite, duration > 0 else { return max(0, target) }
        // Never quite the very end: seeking to exactly the duration parks the
        // player on the last frame in a stopped state, which looks like a crash
        // rather than like the end of a video.
        return min(max(0, target), max(0, duration - 0.05))
    }

    /// How exact a seek needs to be while a finger is moving.
    ///
    /// Zero tolerance forces the decoder back to the previous keyframe and
    /// forward again frame by frame. On phone footage — long-GOP HEVC, keyframes
    /// seconds apart — that is far too slow to track a thumb, and the picture
    /// lags behind the scrubber badly enough that people stop trusting it. A
    /// tolerant seek lands on a nearby keyframe and is effectively instant; the
    /// exact one happens once, on release.
    ///
    /// Scaled to the clip: a 5-second clip needs fine tolerance to be scrubbable
    /// at all, an hour-long one does not.
    public static func scrubTolerance(duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0.5 }
        return min(max(duration / 240, 0.05), 1.0)
    }

    /// `0:07`, `4:31`, `1:02:09`.
    ///
    /// The hours field appears based on the *clip's* length rather than the
    /// current position, so the label doesn't change width as it plays — a
    /// timecode that reflows mid-playback is a surprisingly nasty flicker.
    public static func timecode(_ seconds: Double, duration: Double? = nil) -> String {
        let safe = seconds.isFinite && seconds > 0 ? seconds : 0
        let scale = (duration?.isFinite == true ? max(duration ?? 0, safe) : safe)
        let total = Int(safe.rounded(.down))

        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if scale >= 3600 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes + hours * 60, secs)
    }

    /// One frame at this rate, for stepping. Falls back to 1/30 when the track
    /// won't say — some containers report zero, and a division by it would take
    /// the whole player out.
    public static func frameDuration(nominalFrameRate: Float) -> Double {
        guard nominalFrameRate.isFinite, nominalFrameRate > 0 else { return 1.0 / 30 }
        return 1.0 / Double(nominalFrameRate)
    }

    /// Maps a scrubber position, 0…1, onto a time in the clip.
    public static func time(forFraction fraction: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(fraction, 0), 1) * duration
    }

    /// The inverse, for drawing the scrubber.
    public static func fraction(forTime time: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return min(max(time / duration, 0), 1)
    }
}
