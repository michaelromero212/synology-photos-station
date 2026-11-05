import AsyncHTTPClient
import Foundation
import FrameStationAPI
import NIOCore
import NIOHTTP1

/// The analyzer container's one way in: HTTP over a Unix socket, one request
/// at a time. See NAS-ANALYSIS.md and Analyzer/analyzer/server.py.
///
/// The analyzer is the one component that parses files nobody vetted: every
/// photo and video in the library. So nothing it says is trusted. Answers are
/// capped in size and checked number by number before anything is stored.
struct AnalyzerClient: Sendable {
    /// The request and answer shapes this server understands.
    static let protocolVersion = 1
    /// Far more than any real answer: 12 frames of 768 numbers, and 64 faces
    /// per frame, come to well under a megabyte.
    static let maxResponseBytes = 4 * 1024 * 1024
    static let sceneDimensions = 768
    static let faceDimensions = 128
    static let maxFrames = 16
    static let maxFacesPerFrame = 64

    let socketPath: String
    let http: HTTPClient

    // MARK: - Wire shapes

    struct Health: Decodable, Sendable {
        let status: String
        let `protocol`: Int
        let analyzer: Int
        let models: [String: String]
        let threads: Int

        /// The model ids as one string, in a fixed order, for the record.
        var modelSummary: String {
            models.keys.sorted()
                .map { "\(AnalyzerClient.safeCode($0))=\(AnalyzerClient.safeModel(models[$0] ?? ""))" }
                .joined(separator: ",")
        }
    }

    private struct WireFace: Decodable {
        let box: [Double]
        let landmarks: [Double]
        let score: Double
        let size: Int
        let sharpness: Double
        let embedding: String
    }

    private struct WireFrame: Decodable {
        let ms: Int?
        let width: Int
        let height: Int
        let scene: String
        let faces: [WireFace]
    }

    private struct WireTimings: Decodable {
        let totalMS: Int
    }

    private struct WireResult: Decodable {
        let `protocol`: Int
        let analyzer: Int
        let models: [String: String]
        let frames: [WireFrame]
        let timings: WireTimings
    }

    private struct WireError: Decodable {
        let error: String
    }

    // MARK: - Checked results

    struct Face: Sendable {
        let frame: Int
        let frameMS: Int?
        let box: [Float]
        let landmarks: [Float]
        let score: Float
        let size: Int
        let sharpness: Float
        /// 128 little-endian float32. Biometric: sealed before it's stored,
        /// never logged.
        let embedding: Data
    }

    struct Analysis: Sendable {
        let analyzer: Int
        let models: String
        let frames: Int
        /// frames × 768 little-endian float32.
        let scene: Data
        let faces: [Face]
        let durationMS: Int
    }

    enum Failure: Error, CustomStringConvertible {
        /// No socket, nobody listening, or no answer in time.
        case unreachable(String)
        /// The analyzer looked at the file and declined it; the code says why.
        case rejected(String)
        /// Any other status.
        case status(Int)
        /// An answer that didn't decode or didn't add up.
        case malformed(String)

        var description: String {
            switch self {
            case .unreachable(let why): return "analyzer unreachable (\(why))"
            case .rejected(let code): return "analyzer declined the file (\(code))"
            case .status(let code): return "analyzer answered \(code)"
            case .malformed(let why): return "analyzer answer malformed (\(why))"
            }
        }
    }

    // MARK: - Requests

    func health() async throws -> Health {
        let body = try await send(uri: "/v1/health", method: .GET, body: nil, timeout: .seconds(10))
        do {
            return try JSONDecoder().decode(Health.self, from: body)
        } catch {
            throw Failure.malformed("health")
        }
    }

    /// Asks for one file. `path` is the server's own path to it, which the
    /// analyzer sees at the same place through its read-only mounts.
    func analyze(path: String, kind: MediaType, faces: Bool) async throws -> Analysis {
        struct Body: Encodable {
            let path: String
            let kind: String
            let faces: Bool
        }
        let payload = try JSONEncoder().encode(Body(path: path, kind: kind.rawValue, faces: faces))
        // A video is up to 12 keyframes, each a full decode of a 4K frame on
        // a CPU that's also serving the app.
        let timeout: TimeAmount = kind == .video ? .seconds(600) : .seconds(180)
        let data = try await send(uri: "/v1/analyze", method: .POST, body: payload, timeout: timeout)
        let wire: WireResult
        do {
            wire = try JSONDecoder().decode(WireResult.self, from: data)
        } catch {
            throw Failure.malformed("did not decode")
        }
        return try Self.checked(wire, expectFaces: faces)
    }

    private func send(uri: String, method: HTTPMethod, body: Data?, timeout: TimeAmount) async throws -> Data {
        guard let url = URL(httpURLWithSocketPath: socketPath, uri: uri) else {
            throw Failure.unreachable("bad socket path")
        }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method
        if let body {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: body))
        }

        let response: HTTPClientResponse
        do {
            response = try await http.execute(request, timeout: timeout)
        } catch {
            // The type, not the message: a message could carry the path.
            throw Failure.unreachable(String(describing: type(of: error)))
        }
        let buffer: ByteBuffer
        do {
            buffer = try await response.body.collect(upTo: Self.maxResponseBytes)
        } catch {
            throw Failure.malformed("too large or cut off")
        }
        let bytes = Data(buffer.readableBytesView)

        switch response.status.code {
        case 200:
            return bytes
        case 422:
            let code = (try? JSONDecoder().decode(WireError.self, from: bytes))?.error ?? "unknown"
            throw Failure.rejected(Self.safeCode(code))
        default:
            throw Failure.status(Int(response.status.code))
        }
    }

    /// An error code goes into the database and the logs, so only a short
    /// lowercase word is kept, whatever the analyzer sent.
    static func safeCode(_ code: String) -> String {
        let allowed = code.lowercased().filter { $0.isLetter || $0 == "-" }
        return allowed.isEmpty ? "unknown" : String(allowed.prefix(32))
    }

    // MARK: - Checking

    private static func checked(_ wire: WireResult, expectFaces: Bool) throws -> Analysis {
        guard wire.protocol == protocolVersion else { throw Failure.malformed("protocol \(wire.protocol)") }
        guard (1...maxFrames).contains(wire.frames.count) else { throw Failure.malformed("frame count") }

        var scene = Data()
        scene.reserveCapacity(wire.frames.count * sceneDimensions * 4)
        var faces: [Face] = []
        for (index, frame) in wire.frames.enumerated() {
            guard (1...20_000).contains(frame.width), (1...20_000).contains(frame.height) else {
                throw Failure.malformed("frame size")
            }
            guard let vector = floats(frame.scene, count: sceneDimensions) else {
                throw Failure.malformed("scene vector")
            }
            scene.append(vector)
            guard frame.faces.count <= maxFacesPerFrame, expectFaces || frame.faces.isEmpty else {
                throw Failure.malformed("face count")
            }
            if let ms = frame.ms, ms < 0 { throw Failure.malformed("frame time") }
            for face in frame.faces {
                guard face.box.count == 4, face.landmarks.count == 10,
                      (face.box + face.landmarks).allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      face.score.isFinite, (0...1).contains(face.score),
                      (0...10_000).contains(face.size),
                      face.sharpness.isFinite, face.sharpness >= 0,
                      let embedding = floats(face.embedding, count: faceDimensions)
                else { throw Failure.malformed("face") }
                faces.append(Face(
                    frame: index,
                    frameMS: frame.ms,
                    box: face.box.map { Float($0) },
                    landmarks: face.landmarks.map { Float($0) },
                    score: Float(face.score),
                    size: face.size,
                    sharpness: Float(min(face.sharpness, 1e9)),
                    embedding: embedding
                ))
            }
        }
        let models = wire.models.keys.sorted()
            .map { "\(safeCode($0))=\(safeModel(wire.models[$0] ?? ""))" }
            .joined(separator: ",")
        return Analysis(
            analyzer: wire.analyzer,
            models: String(models.prefix(400)),
            frames: wire.frames.count,
            scene: scene,
            faces: faces,
            durationMS: max(0, wire.timings.totalMS)
        )
    }

    /// A model id such as `yunet-2023mar@8f2383e4dd3c`, reduced to the
    /// characters one can hold, so an answer can't put anything else into a
    /// log line or a row.
    static func safeModel(_ id: String) -> String {
        let allowed = id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "@._-".contains($0)) }
        return String(allowed.prefix(80))
    }

    /// Base64 of exactly `count` little-endian float32, all finite, or nil.
    static func floats(_ base64: String, count: Int) -> Data? {
        guard let data = Data(base64Encoded: base64), data.count == count * 4 else { return nil }
        let finite = data.withUnsafeBytes { raw -> Bool in
            for offset in stride(from: 0, to: raw.count, by: 4) {
                let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                if !Float(bitPattern: bits).isFinite { return false }
            }
            return true
        }
        return finite ? data : nil
    }
}
