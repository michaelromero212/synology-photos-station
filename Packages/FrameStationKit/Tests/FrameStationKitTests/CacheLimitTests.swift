import Foundation
import Testing
@testable import FrameStationKit

@Suite("The image cache stays inside its limit")
struct CacheLimitTests {
    @Test("Limits are decimal, matching every other storage readout on the device")
    func limitsAreDecimal() {
        #expect(CacheLimit.mb250.bytes == 250_000_000)
        #expect(CacheLimit.mb500.bytes == 500_000_000)
        #expect(CacheLimit.gb1.bytes == 1_000_000_000)
        #expect(CacheLimit.gb2.bytes == 2_000_000_000)
    }

    @Test("500 MB is the default, and there is no unbounded option")
    func defaultIsFiveHundredAndBounded() {
        #expect(CacheLimit.default == .mb500)
        #expect(CacheLimit.allCases.count == 4)
        #expect(CacheLimit.allCases.allSatisfy { $0.bytes > 0 })
    }

    @Test("An unknown or missing stored value falls back rather than throwing away the cap")
    func unknownRawValueFallsBack() {
        #expect(CacheLimit.from(rawValue: nil) == .default)
        #expect(CacheLimit.from(rawValue: "gb64") == .default)
        #expect(CacheLimit.from(rawValue: CacheLimit.gb2.rawValue) == .gb2)
    }

    /// The actual bug this closes: the disk tier used to write and never
    /// evict, so a large library filled the phone until iOS purged the lot.
    @Test("Writing past the limit evicts down to the low-water mark")
    func writingPastTheLimitEvicts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fs-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 40 files of 1 KB against a 20 KB cap.
        let payload = Data(repeating: 0xAB, count: 1_000)
        for index in 0..<40 {
            let file = root.appendingPathComponent("entry-\(index)")
            try payload.write(to: file)
            // Distinct, increasing use times so "least recently used" is
            // well-defined rather than dependent on filesystem timestamp
            // resolution.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))],
                ofItemAtPath: file.path
            )
        }

        let loader = ThumbnailLoader(
            client: FrameStationClient(configuration: .init(baseURL: URL(string: "http://x")!)),
            diskLimitBytes: 20_000,
            diskRoot: root
        )

        #expect(await loader.diskCacheSize() == 40_000)
        await loader.setDiskLimit(20_000)

        let after = await loader.diskCacheSize()
        #expect(after <= 20_000, "cache should be under its cap, was \(after)")
        #expect(after > 0, "eviction should stop at the low-water mark, not empty the cache")

        // Least-recently-used goes first: the newest entries must survive.
        let survivors = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(survivors.contains("entry-39"))
        #expect(!survivors.contains("entry-0"))
    }

    @Test("Clearing empties the cache completely")
    func clearingEmptiesTheCache() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fs-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<5 {
            try Data(repeating: 0x01, count: 500)
                .write(to: root.appendingPathComponent("entry-\(index)"))
        }

        let loader = ThumbnailLoader(
            client: FrameStationClient(configuration: .init(baseURL: URL(string: "http://x")!)),
            diskRoot: root
        )
        #expect(await loader.diskCacheSize() == 2_500)
        await loader.clearDiskCache()
        #expect(await loader.diskCacheSize() == 0)
    }
}
