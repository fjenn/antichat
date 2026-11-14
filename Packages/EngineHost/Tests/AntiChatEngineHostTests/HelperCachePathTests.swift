// M9 review E6 (AT-NFR-D7 / AT-226: zero files left after Uninstall): every cache the helper writes lives under
// `EngineListener.Paths.cachesRoot` (Release `~/Library/Caches/AntiChat`, Debug `AntiChat-Dev`), the folder DataPaths
// lists for Uninstall / Remove everything. The `img-erase` Core ML cache was hard-coded to `AntiChat-Dev` in Release.
import Foundation
import Testing
@testable import AntiChatEngineHost

@Suite struct HelperCachePathTests {
    @Test func eraserCacheFollowsTheBuildsCachesFolder() {
        let erase = EngineListener.Paths.eraserCacheDirectory
        #expect(erase.lastPathComponent == "coreml-erase")
        #expect(erase.deletingLastPathComponent().standardizedFileURL == EngineListener.Paths.cachesRoot.standardizedFileURL)
        #expect(EngineListener.Paths.cachesRoot.path.hasSuffix("/Library/Caches/\(EngineListener.Paths.folderName)"))
        #if DEBUG || ANTICHAT_PERF_HARNESS
        #expect(EngineListener.Paths.folderName == "AntiChat-Dev")
        #else
        // The Release name is the one Uninstall lists (tools/ci/antichat-paths.txt: ~/Library/Caches/AntiChat).
        #expect(EngineListener.Paths.folderName == "AntiChat")
        #endif
    }

    /// No helper source spells a per-build cache or log folder itself: a literal `AntiChat-Dev` path would be written
    /// by the Release helper too (only `Paths.folderName` may name it).
    @Test func noHelperSourceHardCodesTheDebugFolder() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AntiChatEngineHost")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("Library/Caches/AntiChat-Dev") || line.contains("Library/Logs/AntiChat-Dev") {
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(scanned > 0, "no helper sources found at \(sources.path)")
        #expect(offenders.isEmpty, "hard-coded Debug folder: \(offenders)")
    }
}
