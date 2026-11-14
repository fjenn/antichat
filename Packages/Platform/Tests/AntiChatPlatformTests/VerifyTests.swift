// AT-NFR-D6 + AT-204 part 1 (R-204 AC4) — M2.T08: every file is sha256-verified before it becomes a blob; a mismatch
// deletes the part and re-fetches once (`download.verifyFailed`), a second mismatch fails (`download.failed`). With
// catalog chunk hashes only the bad chunk is fetched again.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct VerifyTests {
    func run(_ args: [String], chunked: Bool = false) async throws -> (DownloadJob?, [DownloadJob.State], [String?], RangeServer, DL.Blob, DownloadCoordinator) {
        let dir = DL.tempDir("verify")
        let blob = try DL.makeBlob(in: dir, name: "v.bin", size: 24 * TransferConfig.mib)
        let server = try RangeServer(root: dir, args: args)
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: try AppDatabase.inMemory(),
                                     config: TransferConfig(chunkSize: 4 * TransferConfig.mib), sleep: DL.fastSleep)
        let seen = JobTrace()
        dl.observe { if case .state(let j) = $0 { seen.add(j.state, j.errorKey) } }
        let chunk = chunked ? try DL.chunkHashes(blob, chunk: 4 * TransferConfig.mib) : nil
        let job = await dl.enqueue(DL.request(blob, server: server, chunk: chunk))
        let end = await dl.wait(job.id)
        return (end, seen.states, seen.keys, server, blob, dl)
    }

    @Test func corruptOnceRefetchesThenSucceeds() async throws {
        let (end, states, keys, server, blob, dl) = try await run(["--corrupt", "v.bin", "--corrupt-times", "1"])
        #expect(end?.state == .done)
        #expect(states.contains(.verifying))
        #expect(keys.contains("download.verifyFailed"))
        #expect(try Verify.sha256(dl.blobs.url(blob.sha256)) == blob.sha256)
        let sent = await server.settledSent(blob.name, atLeast: 2 * blob.size)
        #expect(sent >= 2 * blob.size && sent <= 2 * blob.size + 4 * TransferConfig.mib, "one full re-fetch, sent \(sent)")
        ATLog.write("AT-NFR-D6", "verify.log", "corruptOnce → done after one re-fetch (sent \(sent) for size \(blob.size))")
    }

    @Test func corruptTwiceFails() async throws {
        let (end, _, keys, _, blob, dl) = try await run(["--corrupt", "v.bin"])
        #expect(end?.state == .failed)
        #expect(end?.errorKey == "download.failed")
        #expect(keys.contains("download.verifyFailed"))
        #expect(!dl.blobs.contains(blob.sha256))
        #expect(!FileManager.default.fileExists(atPath: dl.models.part(blob.sha256).path))
        ATLog.write("AT-NFR-D6", "verify.log", "corruptTwice → failed download.failed, no blob, part deleted")
    }

    @Test func chunkHashRefetchesOnlyTheBadChunk() async throws {
        let (end, _, _, server, blob, dl) = try await run(["--corrupt", "v.bin", "--corrupt-times", "1"], chunked: true)
        #expect(end?.state == .done)
        #expect(dl.blobs.contains(blob.sha256))
        let sent = await server.settledSent(blob.name, atLeast: blob.size)
        #expect(sent - blob.size <= 4 * TransferConfig.mib, "only one chunk again, sent \(sent)")
        ATLog.write("AT-NFR-D6", "verify.log", "chunk hashes: corrupt chunk re-fetched alone (over-fetch \(sent - blob.size))")
    }

    @Test func commitIsIdempotentAndReadOnly() throws {
        let dir = DL.tempDir("commit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let models = ModelsDirectory(root: dir)
        try models.create()
        let store = BlobStore(models: models)
        let blob = try DL.makeBlob(in: models.partial, name: "x.part", size: 1000)
        let u = try store.commit(partial: blob.url, sha256: blob.sha256, verify: true)
        #expect(u.path.hasSuffix("store/sha256/\(blob.sha256.prefix(2))/\(blob.sha256)"))
        #expect(!FileManager.default.isWritableFile(atPath: u.path))
        let again = try DL.makeBlob(in: models.partial, name: "y.part", size: 1000)
        #expect(try store.commit(partial: again.url, sha256: again.sha256) == u)
        #expect(!FileManager.default.fileExists(atPath: again.url.path))
        #expect(throws: BlobStoreError.badDigest("../evil")) { try store.commit(partial: again.url, sha256: "../evil") }
    }
}

final class JobTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var s: [DownloadJob.State] = []
    private var k: [String?] = []
    func add(_ st: DownloadJob.State, _ key: String?) { lock.withLock { s.append(st); k.append(key) } }
    var states: [DownloadJob.State] { lock.withLock { s } }
    var keys: [String?] { lock.withLock { k } }
}
