import Crypto
import FrameStationAPI
import Foundation
import Vapor

/// Walks an existing photo library on disk and decides what is importable.
enum LibraryScanner {
    struct Candidate {
        let url: URL
        let byteSize: Int64
        let modifiedAt: Date
        let mediaType: MediaType
        let mime: String
        /// Basename without extension — used to pair Live Photos.
        let stem: String
    }

    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "tif", "tiff", "bmp",
        // RAW
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef",
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "3gp", "mpg", "mpeg", "wmv", "webm", "mts", "m2ts",
    ]

    /// Directories that must never be walked.
    ///
    /// `@eaDir` is the critical one: Synology scatters it through every folder
    /// on the NAS holding its own generated thumbnails and metadata. Importing
    /// those would fill the library with hundreds of thousands of 120 px
    /// duplicates of photos you already have.
    static let excludedDirectories: Set<String> = [
        "@eaDir", "#recycle", "#snapshot", ".DS_Store", "@tmp", "@sharebin",
        ".Trashes", ".Spotlight-V100", ".fseventsd", "@syno_cache",
    ]

    static func scan(root: URL, logger: Logger) throws -> [Candidate] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.unreadableRoot(root.path)
        }

        var candidates: [Candidate] = []
        var skippedDirectories = 0

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            )

            if values?.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    skippedDirectories += 1
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            let mediaType: MediaType
            if photoExtensions.contains(ext) {
                mediaType = .photo
            } else if videoExtensions.contains(ext) {
                mediaType = .video
            } else {
                continue
            }

            // Apple sidecar for edited photos; the rendered result is a
            // separate file we'll pick up on its own.
            guard !url.lastPathComponent.hasPrefix("._") else { continue }

            candidates.append(
                Candidate(
                    url: url,
                    byteSize: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate ?? Date(),
                    mediaType: mediaType,
                    mime: mimeType(for: ext),
                    stem: url.deletingPathExtension().lastPathComponent
                )
            )
        }

        logger.info("scanned \(root.path): \(candidates.count) media files, skipped \(skippedDirectories) excluded directories")
        return candidates
    }

    /// Groups a still and its paired video into one Live Photo.
    ///
    /// Synology (and the Photos export before it) writes these as `IMG_1234.HEIC`
    /// + `IMG_1234.MOV` in the same folder. Uploading them without pairing gives
    /// you a silent duplicate video sitting next to every Live Photo.
    static func liveGroups(_ candidates: [Candidate]) -> [String: UUID] {
        var byFolderAndStem: [String: [Candidate]] = [:]
        for candidate in candidates {
            let key = candidate.url.deletingLastPathComponent().path + "/" + candidate.stem
            byFolderAndStem[key, default: []].append(candidate)
        }

        var groups: [String: UUID] = [:]
        for (_, group) in byFolderAndStem {
            guard group.count == 2,
                  group.contains(where: { $0.mediaType == .photo }),
                  group.contains(where: { $0.mediaType == .video })
            else { continue }
            let id = UUID()
            for member in group { groups[member.url.path] = id }
        }
        return groups
    }

    /// Streaming SHA-256 — a 4 GB video must not be read into memory.
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func mimeType(for ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "dng": return "image/x-adobe-dng"
        case "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef":
            return "image/x-dcraw"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "3gp": return "video/3gpp"
        case "webm": return "video/webm"
        case "mts", "m2ts": return "video/mp2t"
        case "mpg", "mpeg": return "video/mpeg"
        case "wmv": return "video/x-ms-wmv"
        default: return "application/octet-stream"
        }
    }
}

enum ImportError: Error, CustomStringConvertible {
    case unreadableRoot(String)
    case noSuchSpace(UUID)
    case noSuchUser(UUID)
    case notAMember

    var description: String {
        switch self {
        case .unreadableRoot(let path):
            return "Cannot read \(path)."
        case .noSuchSpace(let id):
            return "No space with id \(id). Run `FrameStationServer spaces` to list them."
        case .noSuchUser(let id):
            return "No user with id \(id). Run `FrameStationServer spaces` to list them."
        case .notAMember:
            return "That user is not a member of that space."
        }
    }
}
