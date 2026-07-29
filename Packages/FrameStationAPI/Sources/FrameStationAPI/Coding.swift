import Foundation

/// The JSON coding contract, shared by the server and every client.
///
/// This exists because the defaults disagree in a way that fails silently at the
/// edges: Vapor encodes `Date` as ISO8601, while a stock `JSONDecoder` uses
/// `.deferredToDate` — seconds since 2001. A client built on defaults would send
/// `774662400` where the server expects `"2026-07-24T19:28:00Z"`, and the only
/// symptom is a 400 on every upload commit that carries a capture date.
///
/// Both sides use these. Neither side constructs a bare `JSONEncoder`.
public enum FrameStationCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
