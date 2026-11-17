// The Skills catalogue (SkillsCatalog) and its installer: the JSON contract of tools/skills, order and search, and
// the download's checks — only pinned https raw.githubusercontent.com URLs, every file's size and SHA-256, no path
// that leaves the skill's folder, nothing left behind on failure. A stub loader stands in for the network.
@testable import AntiChatTools
import CryptoKit
import Foundation
import Testing

@Suite struct SkillsCatalogTests {
    static let commit = String(repeating: "ab12", count: 10)
    static let base = "https://raw.githubusercontent.com/example/skills/\(commit)/skills/brand-voice/"
    static let bodies = ["SKILL.md": "---\nname: brand-voice\ndescription: Writes in the brand's voice.\n---\nBe brief.\n",
                         "reference/tone.md": "Warm and plain.\n"]

    static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func skill(name: String = "brand-voice", base: String = base, commit: String = commit,
                      files: [SkillsCatalog.File]? = nil) -> SkillsCatalog.Skill {
        SkillsCatalog.Skill(id: "example/\(name)", name: name, title: "Brand voice", summary: "Write like the brand", category: "writing",
                            author: "Example", license: "Apache-2.0", commit: commit, base: base,
                            files: files ?? bodies.keys.sorted().map { .init(path: $0, sha256: sha(bodies[$0]!), size: bodies[$0]!.utf8.count) })
    }

    /// Serves `bodies` by the URL's path under the base; anything else is a 404. Counts the requests.
    final class Stub: @unchecked Sendable {
        var served = Stub.bodiesByURL()
        private(set) var requests: [URL] = []
        private let lock = NSLock()
        static func bodiesByURL() -> [String: Data] {
            Dictionary(uniqueKeysWithValues: bodies.map { (base + $0.key, Data($0.value.utf8)) })
        }
        var loader: SkillsCatalogInstaller.Loader {
            { url in
                self.lock.withLock { self.requests.append(url) }
                guard let d = self.served[url.absoluteString] else { return (Data(), 404) }
                return (d, 200)
            }
        }
    }

    static func temp() -> URL {
        let t = FileManager.default.temporaryDirectory.appendingPathComponent("skills-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
        return t
    }

    static func leftovers(_ t: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: t.path)) ?? [] }

    @Test func decodesTheIndex() {
        let json = #"""
        {"generated":"2026-11-16","categories":[{"id":"writing","title":"Writing"},{"id":"design","title":"Design"}],
         "skills":[
          {"id":"a/zine","name":"zine","title":"Zine maker","summary":"Lays out a zine","category":"design","source":"https://github.com/a/b/tree/c/zine","author":"Someone","license":"MIT","commit":"c","base":"https://raw.githubusercontent.com/a/b/c/zine/","files":[{"path":"SKILL.md","sha256":"00","size":3}],"hasScripts":false,"featured":null},
          {"id":"a/memo","name":"memo","title":"Mémo writer","summary":"Short memos","category":"writing","source":"https://github.com/a/b/tree/c/memo","author":"Anthropic","license":"Apache-2.0","commit":"c","base":"https://raw.githubusercontent.com/a/b/c/memo/","files":[{"path":"SKILL.md","sha256":"00","size":3}],"hasScripts":true,"featured":1}
         ]}
        """#
        let c = SkillsCatalog(data: Data(json.utf8))
        #expect(c.categories.map(\.id) == ["writing", "design"])
        #expect(c.skills.map(\.name) == ["memo", "zine"])  // featured first
        #expect(c.skills(in: "design").map(\.name) == ["zine"])
        #expect(c.search("MEMO").map(\.name) == ["memo"] && c.search("anthropic").map(\.name) == ["memo"])
        #expect(c.search("").isEmpty)
        #expect(SkillsCatalog(data: nil).isEmpty && SkillsCatalog(data: Data("x".utf8)).isEmpty)
    }

    /// The bundled index: every entry passes the installer's own checks on its name, base and paths (no request made),
    /// and the bundled notice is the generator's (tools/skills/NOTICE.md).
    @Test func theBundledIndexIsInstallable() throws {
        let c = SkillsCatalog.shared
        #expect(!c.isEmpty)
        for s in c.skills {
            #expect(s.files.contains { $0.path == "SKILL.md" }, "\(s.id)")
            for f in s.files { #expect(throws: Never.self, "\(s.id) \(f.path)") { try SkillsCatalogInstaller.url(s, f) } }
            #expect(c.categories.contains { $0.id == s.category }, "\(s.id)")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../..").standardizedFileURL
        let source = try String(contentsOf: root.appendingPathComponent("tools/skills/NOTICE.md"), encoding: .utf8)
        #expect(SkillsCatalog.notice == source)
    }

    @Test func downloadsAVerifiedSkillIntoAFolderNamedAfterIt() async throws {
        let t = Self.temp(), stub = Stub()
        let folder = try await SkillsCatalogInstaller.download(Self.skill(), temp: t, loader: stub.loader)
        #expect(folder.lastPathComponent == "brand-voice")
        #expect(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) == Self.bodies["SKILL.md"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("reference/tone.md").path))
        #expect(stub.requests.allSatisfy { $0.scheme == "https" && $0.host() == "raw.githubusercontent.com" } && stub.requests.count == 2)
        let candidate = try SkillImporter.inspect(folder)  // the ordinary import path takes it from here
        defer { candidate.discard() }
        #expect(candidate.name == "brand-voice" && candidate.canInstall)
    }

    @Test func aHashMismatchInstallsNothing() async {
        let t = Self.temp(), stub = Stub()
        stub.served[Self.base + "reference/tone.md"] = Data("Warm and plaiN.\n".utf8)  // same size, other bytes
        await #expect(throws: SkillsCatalogInstaller.Failure.hashMismatch(path: "reference/tone.md")) {
            try await SkillsCatalogInstaller.download(Self.skill(), temp: t, loader: stub.loader)
        }
        #expect(Self.leftovers(t).isEmpty)
    }

    @Test func aSizeMismatchInstallsNothing() async {
        let t = Self.temp(), stub = Stub()
        stub.served[Self.base + "SKILL.md"] = Data((Self.bodies["SKILL.md"]! + "more").utf8)
        await #expect(throws: SkillsCatalogInstaller.Failure.sizeMismatch(path: "SKILL.md")) {
            try await SkillsCatalogInstaller.download(Self.skill(), temp: t, loader: stub.loader)
        }
        #expect(Self.leftovers(t).isEmpty)
    }

    @Test func aMissingFileIsAFetchFailure() async {
        let t = Self.temp(), stub = Stub()
        stub.served[Self.base + "reference/tone.md"] = nil
        do {
            _ = try await SkillsCatalogInstaller.download(Self.skill(), temp: t, loader: stub.loader)
            Issue.record("downloaded")
        } catch {
            #expect(error as? SkillsCatalogInstaller.Failure == .fetch(path: "reference/tone.md", status: 404))
            #expect((error as? SkillsCatalogInstaller.Failure)?.isNetwork == true)
        }
        #expect(Self.leftovers(t).isEmpty)
    }

    @Test(arguments: ["../evil.md", "/etc/passwd", "a/../../b.md", "a//b.md", "./SKILL2.md", "a\\b.md", "scripts/..", ""])
    func aPathThatLeavesTheFolderIsRefusedBeforeAnyRequest(_ path: String) async {
        let t = Self.temp(), stub = Stub()
        let files = [SkillsCatalog.File(path: "SKILL.md", sha256: Self.sha(Self.bodies["SKILL.md"]!), size: Self.bodies["SKILL.md"]!.utf8.count),
                     SkillsCatalog.File(path: path, sha256: Self.sha("x"), size: 1)]
        await #expect(throws: SkillsCatalogInstaller.Failure.entry(path)) {
            try await SkillsCatalogInstaller.download(Self.skill(files: files), temp: t, loader: stub.loader)
        }
        #expect(stub.requests.isEmpty && Self.leftovers(t).isEmpty)
    }

    @Test(arguments: ["http://raw.githubusercontent.com/example/skills/COMMIT/s/", "https://evil.example/example/skills/COMMIT/s/",
                      "https://raw.githubusercontent.com.evil.example/e/s/COMMIT/s/", "https://user@raw.githubusercontent.com/e/s/COMMIT/s/",
                      "https://raw.githubusercontent.com:8443/e/s/COMMIT/s/", "https://raw.githubusercontent.com/e/s/main/s/",
                      "https://raw.githubusercontent.com/e/s/COMMIT/s", "https://raw.githubusercontent.com/e/s/COMMIT/../x/",
                      "https://raw.githubusercontent.com/e/s/COMMIT/s/?x=1", "file:///tmp/COMMIT/"])
    func onlyAPinnedRawGitHubBaseIsFetched(_ base: String) async {
        let t = Self.temp(), stub = Stub()
        await #expect(throws: SkillsCatalogInstaller.Failure.entry("base")) {
            try await SkillsCatalogInstaller.download(Self.skill(base: base.replacingOccurrences(of: "COMMIT", with: Self.commit)),
                                                     temp: t, loader: stub.loader)
        }
        #expect(stub.requests.isEmpty && Self.leftovers(t).isEmpty)
    }

    @Test func badNamesAndListingsAreRefused() async {
        let t = Self.temp(), stub = Stub()
        for name in ["", "..", "a/b", "Brand Voice", ".hidden"] {
            await #expect(throws: SkillsCatalogInstaller.Failure.entry("name")) {
                try await SkillsCatalogInstaller.download(Self.skill(name: name), temp: t, loader: stub.loader)
            }
        }
        let noSkillFile = [SkillsCatalog.File(path: "README.md", sha256: Self.sha("x"), size: 1)]
        let huge = [SkillsCatalog.File(path: "SKILL.md", sha256: Self.sha("x"), size: 60 * 1024 * 1024)]
        for files in [noSkillFile, huge] {
            await #expect(throws: SkillsCatalogInstaller.Failure.entry("files")) {
                try await SkillsCatalogInstaller.download(Self.skill(files: files), temp: t, loader: stub.loader)
            }
        }
        #expect(stub.requests.isEmpty && Self.leftovers(t).isEmpty)
    }
}
