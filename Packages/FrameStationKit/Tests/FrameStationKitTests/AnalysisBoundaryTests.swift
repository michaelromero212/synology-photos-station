import Foundation
import XCTest

/// The analyzer's privacy promise, checked against the source itself.
///
/// The promise is that photographs are looked at on the device and nothing in
/// the looking can send one anywhere. A comment can't keep that true as the
/// code changes; these can.
final class AnalysisBoundaryTests: XCTestCase {
    /// `.../Packages/FrameStationKit/Tests/FrameStationKitTests/<this file>`.
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func swiftFiles(under path: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "swift"
                && !$0.path.contains("/.build/") && !$0.path.contains("/build/")
        }
    }

    func testTheAnalyzerCannotReachTheNetwork() throws {
        let files = swiftFiles(under: "Packages/FrameStationKit/Sources/FrameStationAnalysis")
        XCTAssertFalse(files.isEmpty, "Found no analyzer source to check")

        let forbidden = [
            "import FrameStationKit", "import FrameStationAPI", "import Network",
            "import FoundationNetworking", "URLSession", "URLRequest", "NWConnection",
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                XCTAssertFalse(
                    text.contains(word),
                    "\(file.lastPathComponent) uses \(word); the analyzer must not touch the network"
                )
            }
        }
    }

    /// Apple's Private Cloud Compute model runs on Apple's servers. That is
    /// remote inference, which curation rules out entirely.
    func testNothingUsesTheCloudModel() throws {
        // Spelled in two halves so this file doesn't trip its own check.
        let symbol = "PrivateCloudCompute" + "LanguageModel"
        var checked = 0
        for path in ["App", "Packages", "Server/Sources"] {
            for file in swiftFiles(under: path) {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(text.contains(symbol), "\(file.path) uses the cloud model")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 50, "Walked too few files to mean anything")
    }
}
