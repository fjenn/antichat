// AT-204 part 1 (R-204 AC2) — M2.T08: a file is fetched as ≥ 4 simultaneous HTTP Range requests, two files at once.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct ParallelLanesTests {
    @Test func fourRangeLanesPerFileTwoFilesAtOnce() async throws {
        let dir = DL.tempDir("lanes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try DL.makeBlob(in: dir, name: "a.bin", size: 32 * TransferConfig.mib, seed: 1)
        let b = try DL.makeBlob(in: dir, name: "b.bin", size: 32 * TransferConfig.mib, seed: 2)
        let c = try DL.makeBlob(in: dir, name: "c.bin", size: 32 * TransferConfig.mib, seed: 3)
        let server = try RangeServer(root: dir, args: ["--slow", "2000"])
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: nil,
                                     config: TransferConfig(lanes: 4, chunkSize: 2 * TransferConfig.mib), sleep: DL.fastSleep)
        let running = Peak()
        dl.observe { e in if case .state = e { Task { running.note(await dl.allJobs.filter { $0.state == .running }.count) } } }
        let jobs = [await dl.enqueue(DL.request(a, server: server)), await dl.enqueue(DL.request(b, server: server)),
                    await dl.enqueue(DL.request(c, server: server))]
        for j in jobs { #expect(await dl.wait(j.id)?.state == .done) }
        _ = await server.settledSent("c.bin", atLeast: c.size)
        let recs = server.records()
        let perFile = Dictionary(grouping: recs, by: { URL(string: $0.path)!.lastPathComponent }).mapValues { $0.compactMap(\.max_active_path).max() ?? 0 }
        let overall = recs.compactMap(\.max_active).max() ?? 0
        #expect(recs.allSatisfy { $0.range?.hasPrefix("bytes=") == true && $0.status == 206 })
        for (f, n) in perFile { #expect(n >= 4, "\(f): \(n) simultaneous Range requests") }
        // The ≤ 8 ceiling is a client property (≤ 2 running files × 4 lanes), asserted on the client: the server's
        // max_active counts a handler until its last write returns, which can overlap the lane's next request, so
        // `overall` may read 9 on a busy Mac (timing flake, made deterministic per the build brief).
        #expect(overall >= 5, "two files overlapped (saw \(overall))")
        #expect(running.peak <= 2, "≤ 2 files × 4 lanes = ≤ 8 ranges")
        ATLog.write("AT-204", "part1.log", "ParallelLanes: per-file max simultaneous ranges \(perFile.sorted { $0.key < $1.key }), overall \(overall), running ≤ \(running.peak)")
    }
}

final class Peak: @unchecked Sendable {
    private let lock = NSLock()
    private var m = 0
    func note(_ n: Int) { lock.withLock { m = Swift.max(m, n) } }
    var peak: Int { lock.withLock { m } }
}
