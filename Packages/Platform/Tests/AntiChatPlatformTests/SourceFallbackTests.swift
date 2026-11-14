// AT-204 part 1 + AT-220 part 2 (R-220 AC3) — M2.T08: `sources[]` in order; 404/410 moves to the next source; when
// every source fails the job fails with `download.unavailable` ("{pack} model unavailable right now — we'll retry").
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct SourceFallbackTests {
    func coordinator(_ dir: URL) throws -> DownloadCoordinator {
        DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: try AppDatabase.inMemory(),
                            config: TransferConfig(chunkSize: 2 * TransferConfig.mib), sleep: DL.fastSleep)
    }

    @Test(arguments: ["--404", "--410"]) func goneSourceFallsBackToTheNext(flag: String) async throws {
        let dir = DL.tempDir("fallback")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.makeBlob(in: dir, name: "f.bin", size: 9 * TransferConfig.mib)
        let server = try RangeServer(root: dir, args: [flag, "/gone/resolve/\(String(repeating: "a", count: 40))/f.bin"])
        let dl = try coordinator(dir)
        let job = await dl.enqueue(DL.request(blob, server: server, extraSources: [server.url("f.bin", repo: "gone")]))
        let end = await dl.wait(job.id)
        #expect(end?.state == .done)
        #expect(dl.blobs.contains(blob.sha256))
        let recs = server.records()
        #expect(recs.contains { $0.path.hasPrefix("/gone/") && $0.status == (flag == "--404" ? 404 : 410) })
        #expect(recs.contains { $0.path.hasPrefix("/org/repo/") && $0.status == 206 })
        ATLog.write("AT-204", "part1.log", "SourceFallback \(flag): first source gone → second source → done")
        ATLog.write("AT-220", "verify.log", "AC3 SourceFallback \(flag): sources[] in order, 404/410 → next source → verified blob")
    }

    @Test func everySourceGoneFailsWithUnavailable() async throws {
        let dir = DL.tempDir("fallback-all")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.makeBlob(in: dir, name: "g.bin", size: 3 * TransferConfig.mib)
        let server = try RangeServer(root: dir, args: ["--404", "g.bin"])
        let dl = try coordinator(dir)
        var r = DL.request(blob, server: server, extraSources: [server.url("g.bin", repo: "mirror/one")])
        r.pack = "voice"
        let job = await dl.enqueue(r)
        let end = await dl.wait(job.id)
        #expect(end?.state == .failed)
        #expect(end?.errorKey == "download.unavailable")
        #expect(end?.request.pack == "voice")
        #expect(server.records().filter { $0.status == 404 }.count >= 2)
        ATLog.write("AT-220", "verify.log", "AC3 every source 404 → failed download.unavailable (pack voice)")
    }
}
