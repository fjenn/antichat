// M5.T01 task check (D-026: the video runtime installs through M6.T16's RuntimeInstaller, no installer of its own):
// the signed `build/runtimes/signed/video-runtime-<ver>.zip` from `make runtime-video SIGN=1`, described by its
// catalog/runtimes.yaml entry, installs into Runtimes/video-runtime@<ver>/ (sha256 + strict nested signatures) and
// its launcher's --selftest passes from there; a copy with one flipped byte is refused and nothing is installed.
// Skipped (with a note) when the runtime has not been built in this checkout.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct VideoRuntimeInstallTests {
    /// The catalog entry for `video-runtime` (a tiny reader for the flat runtimes.yaml block; the full parser is
    /// catalog-tool's `Spec.runtimes`).
    static func catalogEntry() throws -> CatalogRuntime? {
        let text = try String(contentsOf: DL.repoRoot.appending(path: "catalog/runtimes.yaml"), encoding: .utf8)
        guard let start = text.range(of: "- name: video-runtime\n") else { return nil }
        var fields: [String: String] = [:]
        for line in text[start.upperBound...].split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- name:") || t.hasPrefix("#") { break }
            guard let colon = t.firstIndex(of: ":") else { continue }
            fields[String(t[..<colon])] = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let v = fields["version"], let sha = fields["sha256"], let size = Int64(fields["size_bytes"] ?? "") else { return nil }
        return CatalogRuntime(name: "video-runtime", version: v, sha256: sha, sizeBytes: size, url: fields["url"] ?? "",
                              tiers: ["T2", "T3", "T4"], signatureMode: .adhoc)
    }

    static func signedZip(_ version: String) -> URL? {
        let u = DL.repoRoot.appending(path: "build/runtimes/signed/video-runtime-\(version).zip")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func installer(_ dir: URL) throws -> (RuntimeInstaller, RuntimeRegistry) {
        let registry = RuntimeRegistry(database: try AppDatabase.inMemory())
        return (RuntimeInstaller(paths: RuntimePaths(root: dir.appending(path: "Support/AntiChat-Dev/Runtimes")), registry: registry,
                                 freeBytes: { 500_000_000_000 }), registry)
    }

    @Test func signedZipMatchesTheCatalogAndInstallsAndRunsItsSelftest() async throws {
        let entry = try #require(try Self.catalogEntry())
        guard let zip = Self.signedZip(entry.version) else {
            print("VideoRuntimeInstallTests: skipped, run `make runtime-video SIGN=1` first")
            return
        }
        #expect(try Verify.sha256(zip) == entry.sha256, "catalog/runtimes.yaml sha256 is the signed zip's")
        let dir = DL.tempDir("vrt-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let served = dir.appending(path: zip.lastPathComponent)
        try FileManager.default.copyItem(at: zip, to: served)
        let server = try RangeServer(root: dir, args: [])
        var runtime = entry
        runtime.url = server.url(zip.lastPathComponent).absoluteString
        let (installer, registry) = try Self.installer(dir)
        let installed = try await installer.install(runtime)
        #expect(installed.url.lastPathComponent == "video-runtime@\(entry.version)")
        #expect(try registry.record("video-runtime")?.sha256 == entry.sha256)
        let launcher = installed.url.appending(path: "bin/video-runtime-launcher")
        #expect(FileManager.default.isExecutableFile(atPath: launcher.path))
        // The installed tree runs: imports mlx + FastVideo's Wan2.2 modules, offline, isolated.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", "(version 1)(allow default)(deny network*)", launcher.path, "--selftest"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "selftest: \(line)")
        #expect(line.contains(#""ok": true"#))
    }

    @Test func oneFlippedByteIsRefusedAndNothingIsInstalled() async throws {
        let entry = try #require(try Self.catalogEntry())
        guard let zip = Self.signedZip(entry.version) else { return }
        let dir = DL.tempDir("vrt-flip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let served = dir.appending(path: zip.lastPathComponent)
        try FileManager.default.copyItem(at: zip, to: served)
        let h = try FileHandle(forUpdating: served)
        let offset = UInt64(entry.sizeBytes / 2)
        try h.seek(toOffset: offset)
        let b = try h.read(upToCount: 1) ?? Data([0])
        try h.seek(toOffset: offset)
        try h.write(contentsOf: Data([b[0] ^ 0x01]))
        try h.close()
        let server = try RangeServer(root: dir, args: [])
        var runtime = entry
        runtime.url = server.url(zip.lastPathComponent).absoluteString
        let (installer, registry) = try Self.installer(dir)
        await #expect {
            try await installer.install(runtime)
        } throws: { e in
            if case .verifyFailed = e as? RuntimeInstallError { return true }
            return false
        }
        #expect(installer.installed("video-runtime") == nil)
        #expect(try registry.record("video-runtime") == nil)
        #expect(!FileManager.default.fileExists(atPath: installer.paths.folder(runtime).path))
    }
}
