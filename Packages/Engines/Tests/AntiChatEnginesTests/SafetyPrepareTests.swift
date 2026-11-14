// M4 lead decision (install-time compile of the ChildSafetyCheck detectors): `MediaOutputGate.prepare` compiles a
// detector set into `<cache>/<key of its sha256s>/`, marks it prepared, answers an unchanged set at once, and a model
// change (new sha256) gets a fresh folder; missing/damaged files prepare nothing. Content-free (blank canvases only).
// The real leg (`CSC_REAL_DETECTORS=1`, the dev detector files; memory checked by the caller) compiles cold, then shows
// the first check after a prepare loads from the compiled cache instead of compiling again.
import AntiChatEngineProtocol
import CryptoKit
import Foundation
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct SafetyPrepareTests {
    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "csc-prepare-\(UUID().uuidString)")
    }

    @Test func compiledKeyFollowsTheModelHashes() throws {
        let (dir, m) = try MediaOutputGateTests.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        var changed = m
        changed.sha256["csc-age"] = String(repeating: "0", count: 64)
        var reordered = m
        reordered.sizeBytes += 1  // not part of the key: only the model hashes are
        #expect(MediaOutputGate.compiledKey(m) == MediaOutputGate.compiledKey(reordered))
        #expect(MediaOutputGate.compiledKey(m) != MediaOutputGate.compiledKey(changed))
        #expect(MediaOutputGate.compiledKey(m).count == 16)
    }

    @Test func damagedOrMissingFilesPrepareNothing() async throws {
        let (dir, m) = try MediaOutputGateTests.fakeInstall()  // right hashes, not loadable models
        let cache = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: cache) }
        let gate = MediaOutputGate(manifestProvider: { nil }, cacheDirectory: cache)
        #expect(await gate.prepare(m) == .failed)
        #expect(await !gate.isPrepared(m))
        try FileManager.default.removeItem(atPath: m.agePath)
        #expect(await gate.prepare(m) == .failed)
        #expect(await !gate.isLoaded, "prepare never keeps detectors resident")
        #expect(await MediaOutputGate(manifestProvider: { nil }).prepare(m) == .failed, "no cache folder: nothing to prepare into")
    }

    @Test func preparedSetAnswersAtOnceAndOthersArePruned() async throws {
        let (dir, m) = try MediaOutputGateTests.fakeInstall()
        let cache = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: cache) }
        let gate = MediaOutputGate(manifestProvider: { nil }, cacheDirectory: cache)
        let folder = try #require(await gate.compiledDirectory(m))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appending(path: MediaOutputGate.preparedMarker))
        #expect(await gate.isPrepared(m))
        #expect(await gate.prepare(m) == .alreadyPrepared)  // the fake files would fail to load: nothing was loaded
    }

    // MARK: M9 review E2: one compile per folder at a time, atomically

    /// A fake two-pass compile: records how many run at once, writes a partition file into the folder it is given.
    final class FakeCompiler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var maxRunning = 0
        private(set) var loads: [String] = []
        var failOnLoad: Int?  // 1-based load number that throws
        func load(_ dir: URL) throws -> String {
            let n = lock.withLock { () -> Int in
                running += 1
                maxRunning = max(maxRunning, running)
                loads.append(dir.lastPathComponent)
                return loads.count
            }
            defer { lock.withLock { running -= 1 } }
            Thread.sleep(forTimeInterval: 0.05)
            if n == failOnLoad { throw CocoaError(.fileReadUnknown) }
            let part = dir.appending(path: "123/0_static_mlprogram")
            try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: part.appending(path: "model.mil"))
            return dir.path
        }
    }

    /// The detached `prepare` and the actor's load of the same folder never compile at the same time: the second one
    /// waits for the first and then loads its prepared folder (no second compile).
    @Test func prepareAndLoadOfOneFolderAreSerialised() async throws {
        let cache = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let dir = cache.appending(path: "abcd")
        let fake = FakeCompiler()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<4 {
                g.addTask { _ = try? MediaOutputGate.loadCompiled(dir, key: "abcd") { try fake.load($0) } }
            }
        }
        #expect(fake.maxRunning == 1, "loads of one folder ran side by side")
        #expect(fake.loads.count == 2 + 3, "one two-pass compile, then three plain loads: \(fake.loads)")
        #expect(fake.loads.first?.hasPrefix(".abcd.compiling-") == true, "the compile goes to a temp folder first")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: MediaOutputGate.preparedMarker).path))
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.contains("compiling") }
        #expect(left.isEmpty, "no temp folder left: \(left)")
    }

    /// A compile that fails leaves no prepared marker (so `prepare` never reports prepared and `isPrepared` stays
    /// false), and the next load compiles again into a fresh folder that replaces the leftover.
    @Test func aFailedCompileIsNeverReportedPreparedAndIsRetried() throws {
        let cache = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let dir = cache.appending(path: "abcd")
        let marker = dir.appending(path: MediaOutputGate.preparedMarker)
        // Fails in the temp folder: nothing is renamed into place.
        let first = FakeCompiler()
        first.failOnLoad = 1
        #expect(throws: (any Error).self) { try MediaOutputGate.loadCompiled(dir, key: "abcd") { try first.load($0) } }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // Fails at the warm load after the rename: the folder exists but is not marked.
        let second = FakeCompiler()
        second.failOnLoad = 2
        #expect(throws: (any Error).self) { try MediaOutputGate.loadCompiled(dir, key: "abcd") { try second.load($0) } }
        #expect(FileManager.default.fileExists(atPath: dir.path) && !FileManager.default.fileExists(atPath: marker.path))
        // A torn leftover (no marker) is never loaded as is: it is replaced by a complete compile.
        try Data("torn".utf8).write(to: dir.appending(path: "torn"))
        let third = FakeCompiler()
        #expect(try MediaOutputGate.loadCompiled(dir, key: "abcd") { try third.load($0) } == dir.path)
        #expect(third.loads.count == 2)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "torn").path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.contains("compiling") }
        #expect(left.isEmpty, "no temp folder left: \(left)")
    }

    /// The real `prepare` of an unloadable set leaves no compiled folder and no marker behind.
    @Test func aFailedPrepareLeavesNoFolder() async throws {
        let (dir, m) = try MediaOutputGateTests.fakeInstall()
        let cache = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: cache) }
        let gate = MediaOutputGate(manifestProvider: { m }, cacheDirectory: cache)
        #expect(await gate.prepare(m) == .failed)
        #expect(await !gate.isPrepared(m))
        let folder = try #require(await gate.compiledDirectory(m))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        // The gate's own load of the same set fails closed too, and still marks nothing.
        // (`preload` takes the checks' load path without touching the process-wide trace that MediaOutputGateTests counts.)
        #expect(await gate.preload() == nil)
        #expect(await !gate.isLoaded)
        #expect(await !gate.isPrepared(m))
    }

    static var devModels: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/AntiChat-Dev/Models")
    }

    static func devManifest() throws -> SafetyManifest {
        var paths: [String: String] = [:], sha: [String: String] = [:]
        for (key, file) in [("csc-nudity", "onnx/model.onnx"), ("csc-age", "mivolo_v2_age.onnx"), ("csc-age-bins", "model.safetensors")] {
            let url = devModels.appending(path: "\(key)/\(file)")
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            sha[key] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            paths[key] = url.path
        }
        return SafetyManifest(nudityPath: paths["csc-nudity"]!, agePath: paths["csc-age"]!, ageBinsPath: paths["csc-age-bins"]!,
                              sha256: sha, sizeBytes: 0)
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CSC_REAL_DETECTORS"] == "1"))
    func realDetectorsCompileOnceThenTheFirstCheckLoadsCompiled() async throws {
        let m = try Self.devManifest()
        let cache = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let installer = MediaOutputGate(manifestProvider: { nil }, cacheDirectory: cache)
        let t0 = ContinuousClock.now
        guard case .prepared(let compile) = await installer.prepare(m) else { Issue.record("prepare failed"); return }
        let prepareS = Self.secs(ContinuousClock.now - t0)
        let prepared = await installer.isPrepared(m), loaded = await installer.isLoaded
        #expect(prepared && !loaded)
        #expect(await installer.prepare(m) == .alreadyPrepared)
        // A fresh gate (the helper after a relaunch) on the same cache: the first check loads the compiled models.
        let gate = MediaOutputGate(manifestProvider: { m }, cacheDirectory: cache)
        let t1 = ContinuousClock.now
        #expect(await gate.checkResult(MediaOutputGateTests.blank(256), job: "prep") == .allow)
        let firstCheck = Self.secs(ContinuousClock.now - t1)
        print("SafetyPrepareTests: cold prepare \(prepareS) s (compile \(compile) s), first check after prepare \(firstCheck) s")
        #expect(firstCheck < compile / 2, "the first check must not pay the compile again (\(firstCheck) s vs \(compile) s)")
    }
}
