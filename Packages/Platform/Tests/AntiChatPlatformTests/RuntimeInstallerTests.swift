// M6.T16 (AT-018 check 1, installer part; R-018 AC1, NFR-D2, A-M6-11): the generic RuntimeInstaller against a tiny
// signed runtime zip served by tools/fixtures/range-server.py — sha mismatch → one re-fetch → installed; always
// corrupt → verifyFailed; disk short → diskFull (needed vs available, nothing fetched); a tampered or unsigned
// Mach-O → refused, nothing installed; a symlink out of the tree → refused; the folder is Runtimes/<name>@<ver>
// (fixed Application Support path, never the dev container); SpaceAccountant matches `du -k` within 1 %.
@testable import AntiChatPlatform
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct RuntimeInstallerTests {
    struct Fixture {
        let dir: URL
        let zip: URL
        let runtime: CatalogRuntime
        let server: RangeServer
        let installer: RuntimeInstaller
        let registry: RuntimeRegistry
    }

    static func run(_ tool: String, _ args: [String], cwd: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(args) → \(p.terminationStatus)"]) }
    }

    enum Tamper { case none, flipCode, unsigned, escapeLink }

    /// tree: bin/tool (ad-hoc signed copy of /usr/bin/true) + lib/data.txt + RUNTIME.json → <name>.zip.
    static func makeRuntime(in dir: URL, name: String = "probe-runtime", version: String = "1.2.3", tamper: Tamper = .none) throws -> (URL, CatalogRuntime) {
        let fm = FileManager.default
        let tree = dir.appending(path: "tree-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: tree.appending(path: "bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tree.appending(path: "lib"), withIntermediateDirectories: true)
        let tool = tree.appending(path: "bin/tool")
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: tool)
        if tamper != .unsigned {
            try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", tool.path])
        } else {
            try run("/usr/bin/codesign", ["--remove-signature", tool.path])
        }
        if tamper == .flipCode {
            // Flip one byte inside the first slice's __TEXT (offset 0x2000 is past the header, before the signature).
            let h = try FileHandle(forUpdating: tool)
            try h.seek(toOffset: 0x4100)
            let b = try h.read(upToCount: 1) ?? Data([0])
            try h.seek(toOffset: 0x4100)
            try h.write(contentsOf: Data([b[0] ^ 0xFF]))
            try h.close()
        }
        try Data("runtime payload\n".utf8).write(to: tree.appending(path: "lib/data.txt"))
        try Data(#"{"name":"\#(name)","version":"\#(version)"}"#.utf8).write(to: tree.appending(path: "RUNTIME.json"))
        try fm.createSymbolicLink(atPath: tree.appending(path: "lib/current").path, withDestinationPath: "data.txt")
        if tamper == .escapeLink {
            try fm.createSymbolicLink(atPath: tree.appending(path: "lib/escape").path, withDestinationPath: "../../../../../etc")
        }
        let zip = dir.appending(path: "\(name)-\(version).zip")
        try? fm.removeItem(at: zip)
        try run("/usr/bin/zip", ["-X", "-y", "-q", "-r", zip.path, "."], cwd: tree)
        let size = (try fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (zip, CatalogRuntime(name: name, version: version, sha256: try Verify.sha256(zip), sizeBytes: size, url: ""))
    }

    static func fixture(_ tag: String, tamper: Tamper = .none, serverArgs: [String] = [],
                        free: Int64 = 500_000_000_000) throws -> Fixture {
        let dir = DL.tempDir("rt-\(tag)")
        let (zip, rt) = try makeRuntime(in: dir, tamper: tamper)
        let server = try RangeServer(root: dir, args: serverArgs.map { $0 == "@zip" ? zip.lastPathComponent : $0 })
        var runtime = rt
        runtime.url = server.url(zip.lastPathComponent).absoluteString
        let registry = RuntimeRegistry(database: try AppDatabase.inMemory())
        let installer = RuntimeInstaller(paths: RuntimePaths(root: dir.appending(path: "Support/AntiChat-Dev/Runtimes")), registry: registry,
                                         freeBytes: { free })
        return Fixture(dir: dir, zip: zip, runtime: runtime, server: server, installer: installer, registry: registry)
    }

    @Test func installsIntoRuntimesNameAtVersion() async throws {
        let f = try Self.fixture("ok")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let i = try await f.installer.install(f.runtime)
        let want = f.dir.appending(path: "Support/AntiChat-Dev/Runtimes/probe-runtime@1.2.3").standardizedFileURL
        #expect(i.url.standardizedFileURL == want)
        #expect(FileManager.default.isExecutableFile(atPath: want.appending(path: "bin/tool").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: want.appending(path: "lib/current").path)) == "data.txt")
        let row = try #require(f.registry.record("probe-runtime"))
        #expect(row.version == "1.2.3" && row.sha256 == f.runtime.sha256 && row.path == want.path)
        #expect(f.installer.isCurrent(f.runtime))
        // No leftovers: the verified zip part and the staging folder are gone.
        let root = f.installer.paths.root
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: ".staging").path)) ?? []).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: ".download/partial").path)) ?? []).isEmpty)
        // Second install of the same version is a no-op (no second GET).
        let gets = f.server.records().count
        _ = try await f.installer.install(f.runtime)
        #expect(f.server.records().count == gets)
    }

    @Test func shaMismatchRefetchesOnceThenInstalls() async throws {
        let f = try Self.fixture("refetch", serverArgs: ["--corrupt", "@zip", "--corrupt-times", "1"])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try await f.installer.install(f.runtime)
        #expect(f.installer.installed("probe-runtime") != nil)
        let gets = f.server.records().filter { $0.path.hasSuffix(f.zip.lastPathComponent) && ($0.status == 200 || $0.status == 206) }
        #expect(gets.count >= 2, "first (corrupt) fetch + the re-fetch: \(gets.count)")
    }

    @Test func alwaysCorruptFailsWithVerifyFailedAndInstallsNothing() async throws {
        let f = try Self.fixture("corrupt", serverArgs: ["--corrupt", "@zip"])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        do { try await f.installer.install(f.runtime); Issue.record("expected verifyFailed") } catch let e as RuntimeInstallError {
            guard case .verifyFailed(let expected, _) = e else { Issue.record("got \(e)"); return }
            #expect(expected == f.runtime.sha256)
            #expect(e.copyKey == "download.failed")
        }
        #expect(f.installer.installed("probe-runtime") == nil)
        #expect(!FileManager.default.fileExists(atPath: f.installer.paths.folder(f.runtime).path))
    }

    @Test func diskShortThrowsDiskFullWithNeededAndAvailableBeforeAnyDownload() async throws {
        let free: Int64 = 3_000_000_000
        let f = try Self.fixture("disk", free: free)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        do {
            try await f.installer.install(f.runtime)
            Issue.record("expected diskFull")
        } catch let e as RuntimeInstallError {
            guard case .diskFull(let gb, let needed, let available) = e else { Issue.record("got \(e)"); return }
            #expect(needed == f.runtime.sizeBytes + DiskPreflight.headroomBytes)
            #expect(available == free)
            #expect(gb == Int((Double(needed - free) / 1e9).rounded(.up)))
            #expect(e.copyKey == "download.diskFull")
        }
        #expect(f.server.records().isEmpty, "nothing may be fetched when the disk is short")
    }

    @Test(arguments: [Tamper.flipCode, Tamper.unsigned])
    func badSignatureIsRefusedAndNothingIsInstalled(tamper: Tamper) async throws {
        let f = try Self.fixture("sig-\(tamper)", tamper: tamper)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        do {
            try await f.installer.install(f.runtime)
            Issue.record("expected badSignature")
        } catch let e as RuntimeInstallError {
            guard case .badSignature(let path, let status) = e else { Issue.record("got \(e)"); return }
            #expect(path == "bin/tool")
            #expect(status != 0)
        }
        #expect(f.installer.installed("probe-runtime") == nil)
        #expect(f.registry.record("probe-runtime") == nil)
        #expect(!FileManager.default.fileExists(atPath: f.installer.paths.folder(f.runtime).path))
    }

    @Test func symlinkOutOfTheRuntimeIsRefused() async throws {
        let f = try Self.fixture("escape", tamper: .escapeLink)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        do {
            try await f.installer.install(f.runtime)
            Issue.record("expected badArchive")
        } catch let e as RuntimeInstallError {
            guard case .badArchive = e else { Issue.record("got \(e)"); return }
        }
        #expect(!FileManager.default.fileExists(atPath: f.installer.paths.folder(f.runtime).path))
    }

    /// Review #9: a `../` entry, an absolute entry and a file written through a symlink entry are refused before
    /// anything is extracted (nothing appears outside the staging folder).
    @Test(arguments: ["dotdot", "absolute", "throughLink"])
    func hostileEntriesAreRefusedBeforeExtraction(kind: String) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rt-preflight-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appending(path: "evil.zip"), outside = dir.appending(path: "outside")
        let script = """
        import sys, zipfile
        kind, path, outside = sys.argv[1:4]
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('bin/ok', 'fine')
            if kind == 'dotdot': z.writestr('../escaped', 'x')
            if kind == 'absolute': z.writestr(outside + '/abs', 'x')
            if kind == 'throughLink':
                link = zipfile.ZipInfo('lib'); link.external_attr = (0o120777 << 16); link.create_system = 3
                z.writestr(link, outside)
                z.writestr('lib/planted', 'x')
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", script, kind, zip.path, outside.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(throws: RuntimeInstallError.self) { try RuntimeInstaller.preflight(zip) }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func newVersionReplacesTheOldOneAndRemoveDeletesEverything() async throws {
        let f = try Self.fixture("upgrade")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try await f.installer.install(f.runtime)
        let (zip2, rt2) = try Self.makeRuntime(in: f.dir, version: "1.2.4")
        var r2 = rt2
        r2.url = f.server.url(zip2.lastPathComponent).absoluteString
        try await f.installer.install(r2)
        #expect(f.installer.installed("probe-runtime")?.version == "1.2.4")
        #expect(!FileManager.default.fileExists(atPath: f.installer.paths.folder(f.runtime).path), "1.2.3 removed after 1.2.4 verified")
        try f.installer.remove("probe-runtime")
        #expect(f.installer.installed("probe-runtime") == nil)
        #expect(!FileManager.default.fileExists(atPath: f.installer.paths.folder(r2).path))
        #expect(f.registry.all().isEmpty)
    }

    /// fix/review P2: install and remove run off the main thread (Settings' Task, Remove everything), but their
    /// `runtimeDidChangeNotification` reaches its main-actor observers on the main thread.
    @Test func changeNotificationsArriveOnTheMainThread() async throws {
        let f = try Self.fixture("notify")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        final class Box: @unchecked Sendable { let lock = NSLock(); var seen: [(String, Bool)] = [] }
        let box = Box()
        let token = NotificationCenter.default.addObserver(forName: .init(ToolDefaults.runtimeDidChangeNotification),
                                                           object: nil, queue: nil) { n in
            guard let name = n.object as? String, name == "probe-runtime" else { return }
            let main = pthread_main_np() != 0
            box.lock.withLock { box.seen.append((name, main)) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let installer = f.installer, runtime = f.runtime
        _ = try await Task.detached { try await installer.install(runtime) }.value
        // `install` posts before it returns.
        #expect(box.lock.withLock { box.seen.count } == 1)
        try await Task.detached { try installer.remove("probe-runtime") }.value
        for _ in 0 ..< 200 where box.lock.withLock({ box.seen.count }) < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        let seen = box.lock.withLock { box.seen }
        #expect(seen.count == 2)
        #expect(seen.allSatisfy { $0.1 }, "posted off the main thread: \(seen)")
    }

    @Test func defaultRootIsTheFixedApplicationSupportPathNotTheDevContainer() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(RuntimePaths.default(debug: true).root.path == home + "/Library/Application Support/AntiChat-Dev/Runtimes")
        #expect(RuntimePaths.default(debug: false).root.path == home + "/Library/Application Support/AntiChat/Runtimes")
        #expect(RuntimePaths.default(debug: false).folder(name: "filetools-runtime", version: "0.1.0").lastPathComponent == "filetools-runtime@0.1.0")
    }

    @Test func spaceAccountantReportsRuntimeBytesWithinOnePercentOfDu() async throws {
        let f = try Self.fixture("space")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let i = try await f.installer.install(f.runtime)
        let rows = SpaceAccountant.runtimes(f.registry)
        let row = try #require(rows.first)
        #expect(row.name == "probe-runtime" && row.labelKey == "storage.row.probe")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", i.url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let kb = Int64(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\t").first ?? "0") ?? 0
        let du = kb * 1024
        // du also counts the directories' own blocks; allow 1 % or the directory blocks of this tiny tree.
        #expect(abs(du - row.bytes) <= max(du / 100, 4 * 4096), "du \(du) vs \(row.bytes)")
    }

    @Test func catalogDecodesRuntimesAndEncodesThemBack() throws {
        let url = DL.repoRoot.appending(path: "Packages/Platform/Sources/AntiChatPlatform/Resources/catalog-baseline.json")
        var cat = try ModelCatalog.decode(Data(contentsOf: url))
        let rt = CatalogRuntime(name: "filetools-runtime", version: "0.1.0", sha256: String(repeating: "a", count: 64), sizeBytes: 1,
                                url: "http://localhost:4321/runtimes/filetools-runtime-0.1.0.zip")
        cat.runtimes = [rt]
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let back = try ModelCatalog.decode(e.encode(cat))
        #expect(back.runtime("filetools-runtime") == rt)
        #expect(back.runtime("filetools-runtime")?.folderName == "filetools-runtime@0.1.0")
    }
}
