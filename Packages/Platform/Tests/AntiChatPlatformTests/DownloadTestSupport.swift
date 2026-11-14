// M2.T08 test support: `tools/fixtures/range-server.py` as a child process, deterministic blobs, the server log.
// Sizes: by default a 48 MiB blob in 4 MiB chunks (the unit run stays fast); ANTICHAT_DL_FULL=1 uses the AT sizes —
// fixtures/downloads/blob-1200m.bin (tools/fixtures/make-blobs.py --seed 7, sha256 pinned in lock.json) in 64 MiB
// chunks, `--fail-after 700 MB`. The over-fetch bound is one chunk either way (NFR-D6).
@testable import AntiChatPlatform
import AntiChatStorage
import CryptoKit
import Foundation

enum DL {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let full = ProcessInfo.processInfo.environment["ANTICHAT_DL_FULL"] == "1"
    static let chunk: Int64 = full ? 64 * TransferConfig.mib : 4 * TransferConfig.mib
    static let config = TransferConfig(lanes: 4, chunkSize: chunk)
    static let fastSleep: @Sendable (Double) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(20)) }

    static func tempDir(_ tag: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "antichat-dl-\(tag)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    struct Blob { let url: URL; let size: Int64; let sha256: String; var name: String { url.lastPathComponent } }

    /// A seeded pseudo-random file (xorshift64*), written once per process run.
    static func makeBlob(in dir: URL, name: String, size: Int64, seed: UInt64 = 7) throws -> Blob {
        let url = dir.appending(path: name)
        var x = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var hasher = SHA256()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        var left = size
        while left > 0 {
            let n = Int(min(left, 1 << 20))
            var block = Data(count: n)
            block.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for i in 0..<words.count { x ^= x >> 12; x ^= x << 25; x ^= x >> 27; words[i] = x &* 0x2545_F491_4F6C_DD1D }
            }
            hasher.update(data: block)
            try h.write(contentsOf: block)
            left -= Int64(n)
        }
        try h.close()
        return Blob(url: url, size: size, sha256: Verify.hex(hasher.finalize()))
    }

    /// The AT blob (full mode) or a 48 MiB one.
    static func standardBlob(in dir: URL) throws -> Blob {
        guard full else { return try makeBlob(in: dir, name: "blob-48m.bin", size: 48 * TransferConfig.mib) }
        let fixtures = repoRoot.appending(path: "fixtures/downloads")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", repoRoot.appending(path: "tools/fixtures/make-blobs.py").path, "--seed", "7", "--only", "blob-1200m.bin"]
        try p.run(); p.waitUntilExit()
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appending(path: "lock.json"))) as! [String: Any]
        let entry = (lock["files"] as! [String: Any])["blob-1200m.bin"] as! [String: Any]
        let src = fixtures.appending(path: "blob-1200m.bin")
        let dst = dir.appending(path: "blob-1200m.bin")
        try? FileManager.default.linkItem(at: src, to: dst)
        return Blob(url: dst, size: (entry["size"] as! NSNumber).int64Value, sha256: entry["sha256"] as! String)
    }

    static func request(_ b: Blob, server: RangeServer, extraSources: [URL] = [], chunk: CatalogChunk? = nil) -> DownloadRequest {
        DownloadRequest(sha256: b.sha256, size: b.size, sources: extraSources + [server.url(b.name)], chunk: chunk, pack: "chat")
    }

    static func chunkHashes(_ b: Blob, chunk: Int64) throws -> CatalogChunk {
        var out: [String] = []
        var off: Int64 = 0
        while off < b.size {
            out.append(try Verify.sha256(b.url, offset: off, length: min(chunk, b.size - off)))
            off += chunk
        }
        return CatalogChunk(size: chunk, sha256: out)
    }
}

/// `python3 -I tools/fixtures/range-server.py --root <dir> --log <file> <args>`; stopped (and reaped) on deinit and,
/// for instances a test never released, when the test process exits (atexit). If the test process dies outright,
/// the server notices it was re-parented and exits by itself (range-server.py watchdog).
final class RangeServer: @unchecked Sendable {
    private static let live = NSLock()
    nonisolated(unsafe) private static var pids: Set<Int32> = []
    private static let installExitHook: Void = {
        atexit {
            RangeServer.live.lock()
            let all = RangeServer.pids
            RangeServer.live.unlock()
            for pid in all { kill(pid, SIGTERM) }
        }
    }()

    let process = Process()
    let log: URL
    let port: Int

    /// The test run's tag (`ANTICHAT_TEST_RUN_TOKEN`, set by tools/ci/test-unit.sh), passed as `--run-token` so the
    /// runner's leftover check sees only its own servers.
    static var runToken: String? { ProcessInfo.processInfo.environment["ANTICHAT_TEST_RUN_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } }

    init(root: URL, args: [String] = [], runToken: String? = RangeServer.runToken) throws {
        log = root.appending(path: "range-server-\(UUID().uuidString.prefix(6)).jsonl")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", DL.repoRoot.appending(path: "tools/fixtures/range-server.py").path, "--root", root.path, "--log", log.path]
            + (runToken.map { ["--run-token", $0] } ?? []) + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        _ = Self.installExitHook
        try process.run()
        Self.live.lock(); Self.pids.insert(process.processIdentifier); Self.live.unlock()
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { break }
            line.append(d)
        }
        port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "PORT ", with: "")) ?? 0
    }

    deinit { stop() }

    /// SIGTERM, then SIGKILL after 3 s; polls waitpid instead of `waitUntilExit` (which waited forever in a full test-unit
    /// run when the server did not die on SIGTERM, hanging UpdateRollbackTests in RangeServer.deinit).
    func stop() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        // Liveness by waitpid, not `isRunning`: Foundation learns of the exit through a source that may never fire here.
        func gone() -> Bool {
            var status: Int32 = 0
            let r = waitpid(pid, &status, WNOHANG)
            return r == pid || (r == -1 && errno == ECHILD)
        }
        let deadline = Date().addingTimeInterval(3)
        while !gone(), Date() < deadline { usleep(20_000) }
        if !gone() {
            kill(pid, SIGKILL)
            let hard = Date().addingTimeInterval(5)
            while !gone(), Date() < hard { usleep(20_000) }
        }
        Self.live.lock(); Self.pids.remove(pid); Self.live.unlock()
    }

    /// An HF-shaped URL for a file in the root.
    func url(_ name: String, repo: String = "org/repo") -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(repo)/resolve/\(String(repeating: "a", count: 40))/\(name)")!
    }

    struct Record: Decodable {
        let path: String; let range: String?; let status: Int; let sent: Int64
        let active: Int?; let max_active: Int?; let max_active_path: Int?
    }

    func records() -> [Record] {
        guard let s = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
    }

    func sent(_ name: String) -> Int64 { records().filter { $0.path.hasSuffix("/" + name) }.reduce(0) { $0 + $1.sent } }

    /// Body bytes served for `name`, once the log has caught up with at least `atLeast` (responses log when they end).
    func settledSent(_ name: String, atLeast: Int64) async -> Int64 {
        for _ in 0..<60 {
            let s = sent(name)
            if s >= atLeast { try? await Task.sleep(for: .milliseconds(200)); return sent(name) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return sent(name)
    }
}

/// Writes `build/at/<AT>/<file>` lines (PRD §1.4 rule 1); appends. Only when ANTICHAT_AT_LOG=1 (AT runs), so a plain
/// `make test-unit` leaves the committed logs alone.
enum ATLog {
    static func write(_ at: String, _ file: String, _ line: String) {
        guard ProcessInfo.processInfo.environment["ANTICHAT_AT_LOG"] == "1" else { return }
        let dir = DL.repoRoot.appending(path: "build/at/\(at)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appending(path: file)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(DL.full ? "[full]" : "[small]") \(line)\n"
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: u)
        }
    }
}
