// AT-204 part 1 (R-204 AC3) — M2.T08: pause keeps the part and its bitmap, resume finishes from them, cancel deletes
// both; the queue survives a relaunch (`restore()` from the `download` rows).
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct PauseResumeCancelTests {
    @Test func pauseResumeCancel() async throws {
        let dir = DL.tempDir("prc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.makeBlob(in: dir, name: "p.bin", size: 24 * TransferConfig.mib)
        let other = try DL.makeBlob(in: dir, name: "q.bin", size: 24 * TransferConfig.mib, seed: 9)
        let server = try RangeServer(root: dir, args: ["--slow", "1500"])
        let models = ModelsDirectory(root: dir.appending(path: "Models"))
        let db = try AppDatabase.inMemory()
        let dl = DownloadCoordinator(models: models, database: db, config: TransferConfig(chunkSize: 2 * TransferConfig.mib), sleep: DL.fastSleep)
        let job = await dl.enqueue(DL.request(blob, server: server))
        try await until { (ChunkBitmap.load(models.bitmap(blob.sha256))?.bytesDone ?? 0) > 4 * TransferConfig.mib }
        await dl.pause(job.id)
        #expect(await dl.job(job.id)?.state == .paused)
        #expect(await dl.job(job.id)?.pauseReason == .user)
        try await Task.sleep(for: .milliseconds(300))
        let kept = ChunkBitmap.load(models.bitmap(blob.sha256))
        #expect(kept != nil && kept!.bytesDone > 0)
        #expect(FileManager.default.fileExists(atPath: models.part(blob.sha256).path))
        #expect(try db.read { try DownloadRecord.fetchOne($0, key: job.id) }?.state == "paused")

        await dl.resume(job.id)
        #expect(await dl.wait(job.id)?.state == .done)
        let sent = await server.settledSent(blob.name, atLeast: blob.size)
        #expect(sent - blob.size <= 2 * TransferConfig.mib, "resume after pause over-fetch \(sent - blob.size)")

        let c = await dl.enqueue(DL.request(other, server: server))
        try await until { FileManager.default.fileExists(atPath: models.bitmap(other.sha256).path) }
        await dl.cancel(c.id)
        for _ in 0..<3000 { if await dl.job(c.id)?.state == .cancelled { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await dl.job(c.id)?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: models.part(other.sha256).path))
        ATLog.write("AT-204", "part1.log", "PauseResumeCancel: pause kept bitmap (\(kept?.bytesDone ?? 0) B), resume over-fetch \(sent - blob.size), cancel deleted part")
    }

    @Test func dedupBySHAAndPresentBlobs() async throws {
        let dir = DL.tempDir("dedup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.makeBlob(in: dir, name: "d.bin", size: 2 * TransferConfig.mib)
        let server = try RangeServer(root: dir)
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: nil, sleep: DL.fastSleep)
        let a = await dl.enqueue(DL.request(blob, server: server))
        let b = await dl.enqueue(DL.request(blob, server: server))
        #expect(a.id == b.id)
        #expect(await dl.wait(a.id)?.state == .done)
        let c = await dl.enqueue(DL.request(blob, server: server))
        #expect(c.state == .done)
        _ = await server.settledSent(blob.name, atLeast: blob.size)
        #expect(server.sent(blob.name) == blob.size)
    }

    @Test func restoreRequeuesRunningAndSystemPausedButNotUserPaused() async throws {
        let dir = DL.tempDir("restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.inMemory()
        let sha = { (c: Character) in String(repeating: c, count: 64) }
        try await db.write { d in
            try DownloadRecord(id: "r", fileSHA256: sha("a"), url: "http://127.0.0.1:9/x", bytesTotal: 10, state: "running").insert(d)
            try DownloadRecord(id: "s", fileSHA256: sha("b"), url: "http://127.0.0.1:9/y", bytesTotal: 10, state: "paused", pauseReason: "system").insert(d)
            try DownloadRecord(id: "u", fileSHA256: sha("c"), url: "http://127.0.0.1:9/z", bytesTotal: 10, state: "paused", pauseReason: "user").insert(d)
        }
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir), database: db)
        await dl.setHeld(true)
        try await dl.restore()
        #expect(await dl.job("r")?.state == .queued)
        #expect(await dl.job("s")?.state == .queued)
        #expect(await dl.job("u")?.state == .paused)
        #expect(await dl.job("r")?.request.sources == [URL(string: "http://127.0.0.1:9/x")!])
    }
}

func until(_ timeout: Double = 20, _ cond: @Sendable () async -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while await !cond() {
        guard Date() < end else { Issue.record("condition not met in \(timeout) s"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}
