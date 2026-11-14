// AT-NFR-D6 (NFR-D6) + AT-204 part 1 (R-204 AC3) — M2.T08: a resume after a network loss, and after `kill -9` of the
// downloading process, re-fetches at most one chunk (over-fetch = bytes the server sent − file size), and the result
// is sha256-verified. Range-server logs are the measurement.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct ResumeTests {
    @Test func networkLossResumesWithinOneChunk() async throws {
        let dir = DL.tempDir("resume")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.standardBlob(in: dir)
        let failAfter = DL.full ? 700 * 1_000_000 : blob.size * 7 / 12
        let server = try RangeServer(root: dir, args: ["--fail-after", "\(failAfter)", "--down-for", "0.3"])
        let models = ModelsDirectory(root: dir.appending(path: "Models"))
        // Real chunk-retry delays (1 s, 2 s): the connection is down for 0.3 s.
        let dl = DownloadCoordinator(models: models, database: try AppDatabase.inMemory(), config: DL.config)
        let job = await dl.enqueue(DL.request(blob, server: server))
        let end = await dl.wait(job.id)
        try #require(end?.state == .done, "\(String(describing: end))")
        #expect(try Verify.sha256(dl.blobs.url(blob.sha256)) == blob.sha256)
        let sent = await server.settledSent(blob.name, atLeast: blob.size)
        let over = sent - blob.size
        ATLog.write("AT-NFR-D6", "resume.log", "networkLoss size=\(blob.size) chunk=\(DL.chunk) failAfter=\(failAfter) sent=\(sent) overfetch=\(over)")
        #expect(over >= 0)
        #expect(over <= DL.chunk, "over-fetch \(over) > one chunk \(DL.chunk)")
        #expect(!FileManager.default.fileExists(atPath: models.part(blob.sha256).path))
        #expect(!FileManager.default.fileExists(atPath: models.bitmap(blob.sha256).path))
    }

    /// `antichat-cli download` is killed with SIGKILL at ≥ 40 %, then relaunched with the same container (DB + Models).
    @Test func killNineThenRelaunchResumesWithinOneChunk() async throws {
        let dir = DL.tempDir("kill")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.standardBlob(in: dir)
        // Slow enough that the kill lands mid-transfer: 4 lanes × slow KB/s.
        let server = try RangeServer(root: dir, args: ["--slow", DL.full ? "60000" : "3000"])
        let models = dir.appending(path: "Models")
        let args = ["download", "--models", models.path, "--db", dir.appending(path: "antichat.sqlite").path, "--sha256", blob.sha256,
                    "--size", "\(blob.size)", "--source", server.url(blob.name).absoluteString, "--chunk-mb", "\(DL.chunk / TransferConfig.mib)"]
        let first = try CLI.spawn(args)
        let bitmapURL = ModelsDirectory(root: models).bitmap(blob.sha256)
        var killedAt: Int64 = 0
        // Progress, not a poll budget: wait for 40 % however slowly a loaded host runs the CLI (a 20 s cap ran out at
        // high load); the transfer is throttled, so it cannot finish between two polls. Only a stall (no new bytes
        // for 120 s) ends the wait early.
        var lastDone: Int64 = -1
        var lastProgress = ContinuousClock.now
        while first.isRunning {
            let done = ChunkBitmap.load(bitmapURL)?.bytesDone ?? 0
            if done >= blob.size * 4 / 10 { killedAt = done; break }
            if done != lastDone { lastDone = done; lastProgress = .now }
            if ContinuousClock.now - lastProgress > .seconds(120) { Issue.record("the CLI made no progress for 120 s at \(done) bytes"); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        kill(first.processIdentifier, SIGKILL)
        // Not `waitUntilExit()`: it hung here forever after the SIGKILL (see ChildExit).
        try await ChildExit.wait(first, "SIGKILLed antichat-cli download", limit: .seconds(60))
        #expect(killedAt > 0, "the kill never reached 40 %")
        #expect(first.terminationReason == .uncaughtSignal)
        let second = try CLI.spawn(args)
        try await ChildExit.wait(second, "relaunched antichat-cli download", limit: .seconds(300))
        #expect(second.terminationStatus == 0)
        let blobURL = BlobStore(models: ModelsDirectory(root: models)).url(blob.sha256)
        #expect(try Verify.sha256(blobURL) == blob.sha256)
        let sent = await server.settledSent(blob.name, atLeast: blob.size)
        let over = sent - blob.size
        ATLog.write("AT-NFR-D6", "resume.log", "kill9 size=\(blob.size) chunk=\(DL.chunk) killedAt=\(killedAt) sent=\(sent) overfetch=\(over)")
        #expect(over <= DL.chunk, "over-fetch \(over) > one chunk \(DL.chunk)")
    }
}

enum CLI {
    /// The `antichat-cli` built next to the test bundle (same SwiftPM products directory).
    static var url: URL {
        var candidates = Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }
            .map { $0.bundleURL.deletingLastPathComponent().appending(path: "antichat-cli") }
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appending(path: "antichat-cli")) }
        candidates.append(DL.repoRoot.appending(path: ".build/debug/antichat-cli"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates.last!
    }

    static func spawn(_ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

}
