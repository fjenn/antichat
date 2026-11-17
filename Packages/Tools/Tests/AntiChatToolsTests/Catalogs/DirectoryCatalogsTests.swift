// The self-updating skills index (DirectoryCatalogs), with a stub loader and a temp folder: a newer valid download
// wins and is kept; an older one, a wrong schema, a base on another host or outside the source repositories, a path
// that leaves the skill's folder, an oversized or a half-empty index is ignored; Offline only makes no request; an
// install that never opened Settings › Skills makes none by itself; at most one check a day; an unchanged file is
// not downloaded twice. (The apps of Connections come from the relay: LiveAppCatalogTests.)
@testable import AntiChatTools
import CryptoKit
import Foundation
import Testing

@Suite struct DirectoryCatalogsTests {
    static let url = URL(string: "https://raw.githubusercontent.com/owner/index/main/skills-index.json")!
    static let today = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
    static let commit = String(repeating: "ab12", count: 10)
    static let sources: Set<String> = ["a/b"]

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func row(_ n: Int, name: String? = nil, host: String = "raw.githubusercontent.com", repo: String = "a/b",
                    folder: String? = nil, path: String = "SKILL.md", extraFile: String? = nil) -> String {
        let name = name ?? "skill-\(n)"
        let file = { (p: String) in #"{"path":"\#(p)","sha256":"\#(sha(Data("s\(n)".utf8)))","size":2}"# }
        let files = ([file(path)] + (extraFile.map { [file($0)] } ?? [])).joined(separator: ",")
        return #"{"id":"src/\#(name)","name":"\#(name)","title":"Skill \#(n)","summary":"Does \#(n)","category":"writing","source":"https://github.com/a/b","author":"A","license":"MIT","commit":"\#(commit)","base":"https://\#(host)/\#(repo)/\#(commit)/\#(folder ?? name)/","files":[\#(files)],"hasScripts":false,"featured":null}"#
    }

    static func index(_ day: String, rows: [String]) -> Data {
        Data(#"{"generated":"\#(day)","categories":[{"id":"writing","title":"Writing"}],"skills":[\#(rows.joined(separator: ","))]}"#.utf8)
    }

    static func skills(_ day: String, count: Int = 12, host: String = "raw.githubusercontent.com", repo: String = "a/b",
                       extra: [String] = []) -> Data {
        index(day, rows: (0..<count).map { row($0, host: host, repo: repo) } + extra)
    }

    /// Serves one body at `url` with an ETag (the body's hash); honours If-None-Match; anything else is a 404.
    final class Host: @unchecked Sendable {
        private let lock = NSLock()
        private var body: Data?
        private var log: [URLRequest] = []

        var requests: Int { lock.withLock { log.count } }
        var conditional: Int { lock.withLock { log.filter { $0.value(forHTTPHeaderField: "If-None-Match") != nil }.count } }
        /// Every header any request carried (nothing about the user or the Mac may be among them).
        var headers: Set<String> { lock.withLock { Set(log.flatMap { ($0.allHTTPHeaderFields ?? [:]).keys }) } }

        func put(_ data: Data?) { lock.withLock { body = data } }

        var loader: DirectoryCatalogs.Loader {
            { request in
                self.lock.withLock {
                    self.log.append(request)
                    guard request.url == DirectoryCatalogsTests.url, let d = self.body else { return .init(data: Data(), status: 404) }
                    let etag = "\"\(DirectoryCatalogsTests.sha(d).prefix(16))\""
                    if request.value(forHTTPHeaderField: "If-None-Match") == etag { return .init(data: Data(), status: 304, etag: etag) }
                    return .init(data: d, status: 200, etag: etag)
                }
            }
        }
    }

    /// A clock the test moves.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = DirectoryCatalogsTests.today
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    static func temp() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "directory-catalogs-tests-\(UUID().uuidString)")
    }

    static func make(_ host: Host, dir: URL, offline: Bool = false, bundled: Data = skills("2026-11-10"), clock: Clock = Clock()) -> DirectoryCatalogs {
        DirectoryCatalogs(url: url, directory: dir, bundledSkills: SkillsCatalog(data: bundled), sources: sources,
                          allowed: { !offline }, now: { clock.now }, loader: host.loader)
    }

    @Test func aNewerValidDownloadWinsAndIsKept() async throws {
        let dir = Self.temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let host = Host(), clock = Clock()
        host.put(Self.skills("2026-11-17", count: 14))
        let c = Self.make(host, dir: dir, clock: clock)
        #expect(c.skills.skills.count == 12)

        let posted = OSAllocatedCounter()
        let token = NotificationCenter.default.addObserver(forName: DirectoryCatalogs.didChange, object: c, queue: nil) { note in
            if note.userInfo?["kind"] as? String == DirectoryCatalogs.Kind.skills.rawValue { posted.add() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(await c.refresh(userOpened: true) == .updated)
        #expect(c.skills.generated == "2026-11-17" && c.skills.skills.count == 14)
        #expect(posted.value == 1)
        #expect(FileManager.default.fileExists(atPath: c.fileURL(.skills).path))
        #expect(host.requests == 1)
        #expect(host.headers.isSubset(of: ["If-None-Match"]))

        // At most one check a day: opening the page again, and the timer, ask for nothing.
        #expect(await c.refresh(userOpened: true) == .fresh)
        #expect(await c.refresh(userOpened: false) == .fresh)
        #expect(host.requests == 1)

        // A day later the check is conditional and downloads nothing.
        clock.advance(DirectoryCatalogs.day + 60)
        #expect(await c.refresh(userOpened: false) == .notModified)
        #expect(host.requests == 2 && host.conditional == 1)
        #expect(await c.refresh(userOpened: true) == .fresh)

        // The next launch takes the stored copy without the network.
        let next = Self.make(Host(), dir: dir, offline: true)
        await next.loadCached()
        #expect(next.skills.generated == "2026-11-17" && next.skills.skills.count == 14)
        let newer = Self.make(Host(), dir: dir, offline: true, bundled: Self.skills("2026-11-18"))
        await newer.loadCached()
        #expect(newer.skills.generated == "2026-11-18")  // a newer bundled index beats an older stored one

        // A stored copy that was changed into something the checks refuse is not used.
        try Self.skills("2026-11-19", repo: "evil/fork").write(to: c.fileURL(.skills))
        let tampered = Self.make(Host(), dir: dir, offline: true)
        await tampered.loadCached()
        #expect(tampered.skills.generated == "2026-11-10")
    }

    @Test func olderInvalidForeignAndOversizedDownloadsAreIgnored() async throws {
        func outcome(_ data: Data) async -> DirectoryCatalogs.Outcome {
            let dir = Self.temp(); defer { try? FileManager.default.removeItem(at: dir) }
            let host = Host()
            host.put(data)
            let c = Self.make(host, dir: dir)
            let posted = OSAllocatedCounter()
            let token = NotificationCenter.default.addObserver(forName: DirectoryCatalogs.didChange, object: c, queue: nil) { _ in posted.add() }
            defer { NotificationCenter.default.removeObserver(token) }
            let out = await c.refresh(userOpened: true)
            #expect(c.skills.generated == "2026-11-10" && c.skills.skills.count == 12)
            #expect(!FileManager.default.fileExists(atPath: c.fileURL(.skills).path))
            #expect(posted.value == 0)
            return out
        }
        let day = "2026-11-17"
        let eleven = (0..<11).map { Self.row($0) }
        // Older, or the same day.
        #expect(await outcome(Self.skills("2026-11-09")) == .notNewer)
        #expect(await outcome(Self.skills("2026-11-10")) == .notNewer)
        // Not the schema.
        #expect(await outcome(Data("{}".utf8)) == .schema)
        #expect(await outcome(Data("not json".utf8)) == .schema)
        #expect(await outcome(Self.skills("2026-13-40")) == .schema)
        #expect(await outcome(Self.skills("2027-06-01")) == .schema)  // a day in the future
        #expect(await outcome(Self.index(day, rows: [])) == .schema)  // empty
        #expect(await outcome(Self.skills(day, extra: [Self.row(1)])) == .schema)  // an id twice
        #expect(await outcome(Self.index(day, rows: eleven + [Self.row(11, name: "Bad Name")])) == .schema)
        #expect(await outcome(Self.index(day, rows: eleven + [Self.row(11, path: "README.md")])) == .schema)  // no SKILL.md
        // Another host, http, or a look-alike host.
        #expect(await outcome(Self.skills(day, host: "evil.example")) == .schema)
        #expect(await outcome(Self.skills(day, host: "raw.githubusercontent.com.evil.example")) == .schema)
        #expect(await outcome(Self.skills(day, host: "user@raw.githubusercontent.com")) == .schema)
        #expect(await outcome(Data(String(decoding: Self.skills(day), as: UTF8.self).replacingOccurrences(of: "https://raw.", with: "http://raw.").utf8)) == .schema)
        // The right host, a repository that is not one of the sources.
        #expect(await outcome(Self.skills(day, repo: "evil/fork")) == .foreignSource)
        #expect(await outcome(Self.skills(day, repo: "a/b-evil")) == .foreignSource)
        #expect(await outcome(Self.skills(day, repo: "A/B")) == .foreignSource)
        #expect(await outcome(Self.index(day, rows: eleven + [Self.row(11, repo: "evil/fork")])) == .foreignSource)  // one is enough
        // Paths that leave the skill's folder, in a file or in the base.
        for path in ["../SKILL.md", "/etc/passwd", "a/../../x.md", "./x.md", "a//x.md", "a\\\\x.md", ""] {
            #expect(await outcome(Self.index(day, rows: eleven + [Self.row(11, extraFile: path)])) == .schema, "\(path)")
        }
        #expect(await outcome(Self.index(day, rows: eleven + [Self.row(11, folder: "x/../../../evil/fork/\(Self.commit)/y")])) == .schema)
        #expect(await outcome(Self.index(day, rows: eleven + [Self.row(11, folder: "x/%2e%2e/y")])) != .updated)
        // Too large; fewer than half of what the build ships.
        var big = Self.skills(day)
        big.append(Data(repeating: 0x20, count: DirectoryCatalogs.maxBytes))
        #expect(await outcome(big) == .tooLarge)
        #expect(await outcome(Self.skills(day, count: 5)) == .shrunk)
        #expect(await outcome(Self.skills(day, count: 1)) == .shrunk)
    }

    @Test func halfOfTheBundledCountIsStillAccepted() async {
        let dir = Self.temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let host = Host()
        host.put(Self.skills("2026-11-17", count: 6))
        let c = Self.make(host, dir: dir)
        #expect(await c.refresh(userOpened: true) == .updated)
        #expect(c.skills.skills.count == 6)
    }

    @Test func theSourceRepositoriesAreTheGeneratorsSources() throws {
        // tools/skills/overrides.json `sources` = the repositories compiled into the app.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../..").standardizedFileURL
        struct Overrides: Decodable { struct Source: Decodable { let repo: String }; let sources: [Source] }
        let ov = try JSONDecoder().decode(Overrides.self, from: Data(contentsOf: root.appendingPathComponent("tools/skills/overrides.json")))
        #expect(Set(ov.sources.map(\.repo)) == DirectoryCatalogs.sourceRepositories)
    }

    @Test func theBundledIndexPassesTheDownloadCheck() throws {
        let url = try #require(Bundle.module.url(forResource: "skills-index", withExtension: "json"))
        let data = try Data(contentsOf: url)
        #expect(DirectoryCatalogs.isValid(.skills, data: data))
        #expect(DirectoryCatalogs.isValid(.skills, data: data, floor: (SkillsCatalog.bundled.skills.count + 1) / 2))
        #expect(!DirectoryCatalogs.isValid(.skills, data: data, sources: ["anthropics/skills"]))
        #expect(!SkillsCatalog.bundled.generated.isEmpty)
    }

    @Test func theEndpointMustBeHTTPS() {
        #expect(DirectoryCatalogs.endpoint("https://example.org/x/skills-index.json").absoluteString == "https://example.org/x/skills-index.json")
        for bad in [nil, "", "http://example.org/skills-index.json", "file:///tmp/skills-index.json", "https://", "https://u:p@example.org/x"] {
            #expect(DirectoryCatalogs.endpoint(bad) == DirectoryCatalogs.defaultURL)
        }
        #expect(DirectoryCatalogs.defaultURL.absoluteString == "https://raw.githubusercontent.com/fjenn/antichat-skills-index/main/skills-index.json")
    }

    @Test func offlineOnlyMakesNoRequest() async {
        let dir = Self.temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let host = Host()
        host.put(Self.skills("2026-11-17"))
        let c = Self.make(host, dir: dir, offline: true)
        #expect(await c.refresh(userOpened: true) == .offline)
        #expect(await c.refresh(userOpened: true, force: true) == .offline)
        #expect(await c.refresh(userOpened: false) == .offline)
        #expect(host.requests == 0)
        #expect(c.skills.generated == "2026-11-10")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func anInstallThatNeverOpenedSkillsAsksForNothingByItself() async {
        let dir = Self.temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let host = Host(), clock = Clock()
        host.put(Self.skills("2026-11-17"))
        // Launch and the daily timer, on an install that never opened Settings › Skills: nothing, and nothing stored.
        let launch = Self.make(host, dir: dir, clock: clock)
        await launch.loadCached()
        #expect(await launch.refresh(userOpened: false) == .notOpened)
        clock.advance(3 * DirectoryCatalogs.day)
        #expect(await launch.refresh(userOpened: false) == .notOpened)
        #expect(host.requests == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        // The user opens the page: asked for. From then on the timer of a later launch may check too.
        #expect(await launch.refresh(userOpened: true) == .updated)
        #expect(host.requests == 1)
        host.put(Self.skills("2026-11-19", count: 13))
        clock.advance(DirectoryCatalogs.day + 60)
        let later = Self.make(host, dir: dir, clock: clock)
        await later.loadCached()
        #expect(later.skills.generated == "2026-11-17")
        #expect(await later.refresh(userOpened: false) == .updated)
        #expect(later.skills.generated == "2026-11-19" && later.skills.skills.count == 13)
    }

    @Test func aFailedCheckKeepsTheIndexAndWaits() async {
        let dir = Self.temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let host = Host(), clock = Clock()  // nothing published: 404, like before the repository exists
        let c = Self.make(host, dir: dir, clock: clock)
        #expect(await c.refresh(userOpened: true) == .network)
        #expect(c.skills.generated == "2026-11-10")
        #expect(await c.refresh(userOpened: true) == .fresh)  // not again within the hour
        #expect(host.requests == 1)
        host.put(Self.skills("2026-11-17"))
        clock.advance(DirectoryCatalogs.retry + 60)
        #expect(await c.refresh(userOpened: true) == .updated)
    }
}

/// A counter two threads may touch.
final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
