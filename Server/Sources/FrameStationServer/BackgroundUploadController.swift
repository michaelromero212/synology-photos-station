import Crypto
import FrameStationAPI
import Foundation
import NIOCore
import SQLKit
import Vapor

/// A photo iOS sends on the app's behalf while the app isn't running.
///
/// PhotoKit's background upload extension (iOS 26.1 and later) hands the
/// system a file and a destination, and the system sends the file when the
/// network and the battery allow. That's how a photo reaches the NAS minutes
/// after it's taken, with the app closed. The whole request body is the file,
/// so everything else about it rides in a header (`BackgroundUploadRequest`).
///
/// It ends exactly the way a chunked upload's commit does
/// (`UploadController.record`), and follows the probe's rules first: a photo
/// removed on purpose isn't brought back, and one the person already has is
/// linked rather than stored twice.
///
/// Not resumable. iOS first asks, with an `OPTIONS` request, whether the server
/// speaks the draft resumable-upload protocol, and a 501 says no. Saying yes
/// would mean answering mid-request with a 104, which DSM's reverse proxy can't
/// be relied on to pass through. So iOS sends each file whole, and starts over
/// if a transfer drops. Photos are small, and a long video that keeps failing
/// is picked up by the app's own chunked upload the next time it opens.
struct BackgroundUploadController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Unauthenticated: iOS asks before it sends anything of the app's.
        routes.on(.OPTIONS, "uploads", "background", use: options)
        routes
            .grouped(DeviceTokenAuthenticator())
            .grouped(AuthenticatedDevice.guardMiddleware())
            .on(.POST, "uploads", "background", body: .stream, use: upload)
    }

    @Sendable
    func options(req: Request) async throws -> Response {
        Response(status: .notImplemented)
    }

    @Sendable
    func upload(req: Request) async throws -> Response {
        let device = try req.auth.require(AuthenticatedDevice.self)
        guard let value = req.headers.first(name: BackgroundUploadRequest.header),
              let input = BackgroundUploadRequest(headerValue: value)
        else {
            throw Abort(.badRequest, reason: "Missing or unreadable \(BackgroundUploadRequest.header).")
        }
        let spaceID = input.commit.spaceID
        try await SpaceAccess.requireContributor(
            spaceID: spaceID, userID: device.userID, on: req.sql
        )

        // Staged where a chunked upload's file is, under an id of its own.
        let store = req.blobStore
        let stagingID = UUID()
        let received: Received
        do {
            received = try await Self.receive(
                req.body, into: store.uploadDataPath(uploadID: stagingID),
                threadPool: req.application.threadPool
            )
        } catch {
            store.discardStaging(uploadID: stagingID)
            throw error
        }
        guard received.bytes > 0 else {
            store.discardStaging(uploadID: stagingID)
            throw Abort(.badRequest, reason: "Empty upload.")
        }
        if let expected = input.byteSize, expected != received.bytes {
            store.discardStaging(uploadID: stagingID)
            throw Abort(.badRequest, reason: "Expected \(expected) bytes, got \(received.bytes).")
        }

        let sha = received.sha256
        if input.isAutomaticBackup,
           try await UploadController.removedOnPurpose(
               sha256: sha, spaceID: spaceID, userID: device.userID, on: req.sql
           ) {
            store.discardStaging(uploadID: stagingID)
            req.logger.info("background upload \(input.filename): removed on purpose, not kept")
            return Self.respond(.removed, nil)
        }
        if let existing = try await UploadController.visibleAsset(
            sha256: sha, userID: device.userID, on: req.sql
        ) {
            store.discardStaging(uploadID: stagingID)
            let placed = try await UploadController.place(
                assetID: existing, in: spaceID, sourceLocalID: input.commit.sourceLocalID,
                mediaType: input.commit.mediaType, device: device, req: req
            )
            return Self.respond(.have, placed)
        }

        let fileExtension = BlobStore.fileExtension(for: input.filename)
        let blob = try await req.application.threadPool.runIfActive {
            try store.keepStaged(uploadID: stagingID, sha256: sha, fileExtension: fileExtension)
        }
        // As in `commit`: lean, and a read that fails costs the photo nothing.
        var probed: MediaProbe.Metadata?
        do {
            probed = try await MediaProbe.probe(
                url: blob, mediaType: input.commit.mediaType, dumpExif: false
            )
        } catch {
            req.logger.warning("inline metadata probe failed for \(input.filename): \(error)")
        }
        let result = try await UploadController.record(
            sha256: sha, byteSize: received.bytes, filename: input.filename,
            fileExtension: fileExtension, input: input.commit, probed: probed,
            device: device, uploadID: nil, req: req
        )
        // A change number of zero is the photo that was already here: another
        // upload of the same file got there first. See `UploadController.record`.
        let outcome: BackgroundUploadResult = result.changeSeq == 0 ? .have : .stored
        req.logger.info(
            "background upload \(input.filename) (\(received.bytes) bytes): \(outcome.rawValue)"
        )
        return Self.respond(outcome, result)
    }

    /// The answer iOS keeps for the app: the outcome and the asset in headers,
    /// which is all of a response the extension gets to read.
    private static func respond(
        _ outcome: BackgroundUploadResult, _ result: CommitUploadResponse?
    ) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: BackgroundUploadRequest.resultHeader, value: outcome.rawValue)
        if let result {
            headers.replaceOrAdd(
                name: BackgroundUploadRequest.assetIDHeader, value: result.assetID.uuidString
            )
        }
        let response = Response(status: outcome == .stored ? .created : .ok, headers: headers)
        if let result {
            try? response.content.encode(result, using: FrameStationCoding.encoder)
        }
        return response
    }

    // MARK: - Receiving

    struct Received {
        let sha256: String
        let bytes: Int64
    }

    /// How much of a body is gathered before it's written. A body arrives in
    /// pieces of tens of kilobytes, and a trip to the thread pool for each one
    /// would be most of the time a long video took.
    static let writeBytes = 4 * 1024 * 1024

    /// Writes a request body to `destination` as it arrives, hashing it on the
    /// way, never holding more than a few megabytes of it.
    static func receive(
        _ body: Request.Body, into destination: URL, threadPool: NIOThreadPool
    ) async throws -> Received {
        let sink = try FileSink(creating: destination)
        do {
            var pending = ByteBuffer()
            for try await var piece in body {
                pending.writeBuffer(&piece)
                if pending.readableBytes >= writeBytes {
                    let data = Data(pending.readableBytesView)
                    pending.clear()
                    try await threadPool.runIfActive { try sink.write(data) }
                }
            }
            if pending.readableBytes > 0 {
                let data = Data(pending.readableBytesView)
                try await threadPool.runIfActive { try sink.write(data) }
            }
            return try await threadPool.runIfActive { try sink.finish() }
        } catch {
            sink.abandon()
            throw error
        }
    }

    /// One file being written and hashed. Only ever used one write at a time,
    /// each awaited before the next, which is what makes it safe to hand to
    /// the thread pool.
    private final class FileSink: @unchecked Sendable {
        private let handle: FileHandle
        private var hasher = SHA256()
        private var count: Int64 = 0

        init(creating url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw Abort(.internalServerError, reason: "Could not stage the upload.")
            }
            handle = try FileHandle(forWritingTo: url)
        }

        func write(_ data: Data) throws {
            hasher.update(data: data)
            try handle.write(contentsOf: data)
            count += Int64(data.count)
        }

        func finish() throws -> Received {
            try handle.close()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return Received(sha256: digest, bytes: count)
        }

        func abandon() {
            try? handle.close()
        }
    }
}
