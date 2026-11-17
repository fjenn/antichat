// Keeps the skills directory of Settings › Skills (`skills-index.json`) current without an app update and without
// anyone publishing anything: a public repository regenerates the index from its sources every week (its own
// workflow: generator + validator, tools/skills), and every install fetches the file from that repository
// (`Config/Endpoints.plist` `SkillsIndexURL`, raw.githubusercontent.com).
//   * `refresh(userOpened:)`: one conditional GET (`If-None-Match`) through the gate (category `.catalog`, like the
//     model catalogue and the skill downloads), at most once a day. When the user opens Settings › Skills
//     (`userOpened: true`) it is asked for when the last check is a day old. At launch and on the daily timer
//     (`userOpened: false`) only for an install that has opened that page before: an install that never looked at
//     skills sends nothing by itself (the same rule as the apps list, `LiveAppCatalog`). Never in Offline only.
//   * A download is used only when all of this holds; anything else keeps the current index, silently:
//       - at most `maxBytes`, and it decodes under the strict schema (`problem`);
//       - its `generated` day is later than the index in use (bundled or downloaded);
//       - every skill's `base` is https on raw.githubusercontent.com, under one of `sourceRepositories` (compiled
//         in) at the skill's own 40-hex commit, and every file path is relative without `.` / `..` parts;
//       - it has skills, and no fewer than half of what this build ships.
//   * `loadCached()`: the last accepted download in `<support>/Catalog/`, checked again by the same rules.
// There is no detached signature on this file (there was one; it needed the owner's offline key and a site deploy
// for every refresh, so in practice the list never moved). What the list is trusted on instead:
//   1. it comes from the owner's GitHub repository over TLS;
//   2. it can only name files in the three source repositories compiled in here, each pinned to a commit, so it
//      cannot point an install at another host or another project. (GitHub also serves a fork's commits under the
//      parent repository's name, so this narrows what a tampered index could list; it does not make 3-5 optional.)
//   3. every file is checked against the index's size and SHA-256 when a skill is installed
//      (`SkillsCatalogInstaller`), so what is installed is what the index's validator downloaded and checked;
//   4. nothing is installed without the review sheet, which shows the whole skill first;
//   5. a skill's scripts only ever run in the sandbox, after their own approval.
// The model catalogue keeps its signature (`CatalogStore`, `CatalogVerifier`): it decides what gets downloaded and
// run without a review step.
// `SkillsCatalog.shared` reads `live`; `didChange` is posted (main thread) when the index was replaced. The request
// carries nothing about the user or the Mac.
// The apps of Settings › Connections: every install asks the relay which apps exist (`LiveAppCatalog`, which posts
// the same `didChange` with kind `composio-catalog`).
import AntiChatFoundation
import AntiChatNetwork
import Foundation
import os

public final class DirectoryCatalogs: @unchecked Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case skills = "skills-index"
        public var fileName: String { rawValue + ".json" }
    }

    /// What one refresh came to.
    public enum Outcome: String, Sendable, Equatable {
        case updated, notModified, notNewer
        /// Checked less than a day ago: no request.
        case fresh
        case offline
        /// A background check for an install that never opened Settings › Skills: no request.
        case notOpened
        case network, tooLarge
        /// Refused: not the schema, a base outside the source repositories, far fewer skills than this build ships.
        case schema, foreignSource, shrunk
    }

    public struct Response: Sendable {
        public var data: Data
        public var status: Int
        public var etag: String?
        public init(data: Data, status: Int, etag: String? = nil) { self.data = data; self.status = status; self.etag = etag }
    }

    /// One GET; the request carries `If-None-Match` when a previous answer is known.
    public typealias Loader = @Sendable (URLRequest) async throws -> Response

    /// Posted on the main thread when the skills index was replaced by a newer one (`userInfo["kind"]` =
    /// `Kind.rawValue`: read `SkillsCatalog.shared` again), and by `LiveAppCatalog` when the list of apps changed
    /// (`userInfo["kind"]` = `LiveAppCatalog.kind`: read `ComposioCatalog.shared` again).
    public static let didChange = Notification.Name("AntiChatDirectoryCatalogsDidChange")
    /// The index is nowhere near this (about 0.4 MB).
    public static let maxBytes = 4 * 1024 * 1024
    public static let day: TimeInterval = 24 * 3600
    /// After a failed check the next one waits this long.
    public static let retry: TimeInterval = 3600

    /// Where the index is fetched from when `Endpoints.plist` has no usable `SkillsIndexURL`.
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/fjenn/antichat-skills-index/main/skills-index.json")!
    /// The only repositories a skill may be downloaded from (`<owner>/<repo>` on raw.githubusercontent.com): the
    /// `sources` of tools/skills/overrides.json. A new source needs an app update, on purpose.
    public static let sourceRepositories: Set<String> = [
        "anthropics/knowledge-work-plugins", "anthropics/skills", "alirezarezvani/claude-skills",
    ]

    /// The instance `SkillsCatalog.shared` reads (set by `start`).
    public static var live: DirectoryCatalogs? {
        get { liveBox.withLock { $0 } }
        set { liveBox.withLock { $0 = newValue } }
    }
    private static let liveBox = OSAllocatedUnfairLock<DirectoryCatalogs?>(initialState: nil)

    public let url: URL
    public let directory: URL
    private let sources: Set<String>
    private let loader: Loader
    private let allowed: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let bundledSkills: SkillsCatalog
    private struct State {
        var skills: SkillsCatalog?
        var lastFailure: Date?
        var running: Task<Outcome, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `url` = the index file; `directory` = where the downloaded copy is kept.
    public init(url: URL = DirectoryCatalogs.defaultURL, directory: URL, bundledSkills: SkillsCatalog = .bundled,
                sources: Set<String> = DirectoryCatalogs.sourceRepositories,
                allowed: @escaping @Sendable () -> Bool = { NetworkPolicyStore.shared.isEnabled(.catalog) },
                now: @escaping @Sendable () -> Date = Date.init, loader: @escaping Loader = DirectoryCatalogs.gated) {
        self.url = url; self.directory = directory; self.sources = sources; self.loader = loader
        self.allowed = allowed; self.now = now; self.bundledSkills = bundledSkills
    }

    /// `configured` (Endpoints.plist `SkillsIndexURL`) when it is an https URL with a host, else `defaultURL`.
    public static func endpoint(_ configured: String?) -> URL {
        guard let s = configured, let c = URLComponents(string: s), c.scheme == "https", !(c.host ?? "").isEmpty,
              c.user == nil, c.password == nil, let u = c.url else { return defaultURL }
        return u
    }

    // MARK: Reads

    public var skills: SkillsCatalog { state.withLock { $0.skills } ?? bundledSkills }

    // MARK: Launch

    /// Makes an instance `live`, loads what was downloaded before, then checks now and every `interval` (24 h) at
    /// background priority until the task is cancelled; only for an install that has opened Settings › Skills.
    @discardableResult
    public static func start(url: URL, directory: URL, interval: Duration = .seconds(24 * 3600)) -> Task<Void, Never> {
        let catalogs = DirectoryCatalogs(url: url, directory: directory)
        live = catalogs
        return Task.detached(priority: .background) {
            await catalogs.loadCached()
            while !Task.isCancelled {
                await catalogs.refresh(userOpened: false)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Takes the downloaded copy when it still passes every check and is newer than what is current.
    public func loadCached() async {
        guard let data = try? Data(contentsOf: fileURL(.skills)), data.count <= Self.maxBytes,
              Self.problem(data, today: now(), sources: sources, floor: floor) == nil else { return }
        if install(data) { await announce() }
    }

    // MARK: Refresh

    /// Checks the index when the last check is a day old (`force`: now). `userOpened` false (launch, the daily
    /// timer) = only for an install that opened Settings › Skills before; true = the user opened that page.
    /// Never throws; the outcome is for logs and tests.
    @discardableResult
    public func refresh(userOpened: Bool, force: Bool = false) async -> Outcome {
        let task: Task<Outcome, Never> = state.withLock { s in
            if let t = s.running { return t }
            let t = Task { await self.check(userOpened: userOpened, force: force) }
            s.running = t
            return t
        }
        let outcome = await task.value
        state.withLock { $0.running = nil }
        if outcome != .notModified, outcome != .notNewer, outcome != .offline, outcome != .fresh, outcome != .notOpened {
            // Not reachable is ordinary (no connection, the repository not there yet): only what was downloaded
            // and refused is an error.
            AppLog.log(.catalog, outcome == .updated || outcome == .network ? .info : .error,
                       "catalog: skills-index \(outcome.rawValue) (\(skills.generated))")
        }
        return outcome
    }

    /// The fewest skills a download may have: half of what this build ships, and never none.
    private var floor: Int { max(1, (bundledSkills.skills.count + 1) / 2) }

    private func check(userOpened: Bool, force: Bool) async -> Outcome {
        guard allowed() else { return .offline }
        var seen = loadSeen()
        guard userOpened || seen != nil else { return .notOpened }
        // An ETag stands for bytes that were judged once, against this address and this build's index.
        let judged = seen.flatMap { $0.url == url.absoluteString && $0.bundled == bundledSkills.generated ? $0 : nil }
        let t = now()
        if !force {
            if let f = state.withLock({ $0.lastFailure }), t.timeIntervalSince(f) < Self.retry, t >= f { return .fresh }
            if let at = judged?.checkedAt, t.timeIntervalSince(at) < Self.day, t >= at { return .fresh }
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = judged?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // The page was opened: from now on the timer may check too, whatever this request comes to.
        if seen == nil { seen = Seen(url: url.absoluteString, bundled: bundledSkills.generated); saveSeen(seen!) }
        let answer: Response
        do {
            answer = try await loader(request)
        } catch {
            if NetworkGate.map(error) != nil { return .offline }
            state.withLock { $0.lastFailure = t }
            return .network
        }
        if answer.status == 304 {
            saveSeen(Seen(url: url.absoluteString, bundled: bundledSkills.generated, etag: judged?.etag, checkedAt: t))
            return .notModified
        }
        guard answer.status == 200 else {
            state.withLock { $0.lastFailure = t }
            return .network
        }
        let outcome: Outcome
        if answer.data.count > Self.maxBytes {
            outcome = .tooLarge
        } else if let refused = Self.problem(answer.data, today: t, sources: sources, floor: floor) {
            outcome = refused
        } else if install(answer.data) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try answer.data.write(to: fileURL(.skills), options: .atomic)
            } catch {
                AppLog.log(.catalog, .error, "catalog: skills-index could not be stored: \(error)")
            }
            await announce()
            outcome = .updated
        } else {
            outcome = .notNewer
        }
        // These bytes were judged: the same bytes (same ETag) need not be downloaded again.
        state.withLock { $0.lastFailure = nil }
        saveSeen(Seen(url: url.absoluteString, bundled: bundledSkills.generated, etag: answer.etag.flatMap { $0.isEmpty ? nil : $0 },
                      checkedAt: t))
        return outcome
    }

    /// Replaces the current index when `data` (valid) was generated on a later day.
    private func install(_ data: Data) -> Bool {
        let c = SkillsCatalog(data: data)
        guard c.generated > skills.generated else { return false }
        state.withLock { $0.skills = c }
        return true
    }

    private func announce() async {
        await MainActor.run {
            NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["kind": Kind.skills.rawValue])
        }
    }

    // MARK: Files

    func fileURL(_ kind: Kind) -> URL { directory.appending(path: kind.fileName) }
    private var seenURL: URL { directory.appending(path: "skills-index-state.json") }

    /// That this file exists says Settings › Skills was opened once (the timer may check from then on).
    private struct Seen: Codable { var url: String; var bundled: String; var etag: String?; var checkedAt: Date? }

    private func loadSeen() -> Seen? {
        (try? Data(contentsOf: seenURL)).flatMap { try? JSONDecoder().decode(Seen.self, from: $0) }
    }

    private func saveSeen(_ seen: Seen) {
        guard let data = try? JSONEncoder().encode(seen) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: seenURL, options: .atomic)
    }

    // MARK: Checks

    /// Whether `data` is an index the app would take (the bundled one must pass too: DirectoryCatalogsTests).
    public static func isValid(_ kind: Kind, data: Data, today: Date = Date(), sources: Set<String> = sourceRepositories,
                               floor: Int = 1) -> Bool {
        problem(data, today: today, sources: sources, floor: floor) == nil
    }

    private static let slugCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
    private static let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")

    static func isSlug(_ s: String) -> Bool { (1...64).contains(s.count) && s.unicodeScalars.allSatisfy(slugCharacters.contains) }
    static func isSHA256(_ s: String) -> Bool { s.count == 64 && s.unicodeScalars.allSatisfy(hexCharacters.contains) }

    /// `yyyy-mm-dd`, a real day, and not later than tomorrow (a far-future day would shut out every later catalogue).
    static func isDay(_ s: String, today: Date) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard s.count == 10, let day = f.date(from: s), f.string(from: day) == s else { return false }
        return day <= today.addingTimeInterval(36 * 3600)
    }

    private static func validCategories(_ list: [ComposioCatalog.Category]) -> Set<String>? {
        let ids = Set(list.map(\.id))
        guard !list.isEmpty, list.count <= 64, ids.count == list.count,
              list.allSatisfy({ isSlug($0.id) && !$0.title.isEmpty && $0.title.count <= 40 }) else { return nil }
        return ids
    }

    /// `base` is `https://raw.githubusercontent.com/<owner>/<repo>/<commit>/<folder>/` with `<owner>/<repo>` one of
    /// `sources` and `<commit>` the skill's own.
    static func isFromSource(_ skill: SkillsCatalog.Skill, sources: Set<String>) -> Bool {
        guard let c = URLComponents(string: skill.base), c.scheme == "https", c.host == SkillsCatalogInstaller.host,
              c.percentEncodedPath == c.path else { return false }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // "", owner, repo, commit, folder…, ""
        guard parts.count >= 6, parts.first == "", parts.last == "", sources.contains("\(parts[1])/\(parts[2])"),
              parts[3] == skill.commit, parts[4..<(parts.count - 1)].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return false }
        return true
    }

    /// Why `data` is refused (`schema`, `foreignSource`, `shrunk`); nil = it may be used when it is newer.
    static func problem(_ data: Data, today: Date, sources: Set<String>, floor: Int) -> Outcome? {
        struct File: Decodable { let generated: String; let categories: [ComposioCatalog.Category]; let skills: [SkillsCatalog.Skill] }
        guard let f = try? JSONDecoder().decode(File.self, from: data), isDay(f.generated, today: today),
              let ids = validCategories(f.categories), (1...5_000).contains(f.skills.count),
              Set(f.skills.map(\.id)).count == f.skills.count, Set(f.skills.map(\.name)).count == f.skills.count
        else { return .schema }
        for s in f.skills {
            guard !s.title.isEmpty, s.title.count <= 80, s.summary.count <= 120, ids.contains(s.category),
                  !s.id.isEmpty, s.id.count <= 140, isSlug(s.name), !s.files.isEmpty, s.files.count <= 500,
                  s.files.contains(where: { $0.path == "SKILL.md" }),
                  Set(s.files.map { $0.path.lowercased() }).count == s.files.count else { return .schema }
            // Every file must be one the installer would fetch: https, raw.githubusercontent.com, the pinned
            // commit, a relative path without `.` or `..` parts.
            guard s.files.allSatisfy({ $0.size >= 0 && isSHA256($0.sha256) && (try? SkillsCatalogInstaller.url(s, $0)) != nil })
            else { return .schema }
            guard isFromSource(s, sources: sources) else { return .foreignSource }
        }
        return f.skills.count < floor ? .shrunk : nil
    }

    // MARK: Network

    /// GET through the gate (category `.catalog`): Offline only and the category switch apply, and the request is
    /// recorded in Network activity, exactly like the model catalogue's.
    public static let gated: Loader = { request in
        let (data, response) = try await NetworkGate.gated(.catalog).data(for: request)
        let http = response as? HTTPURLResponse
        return Response(data: data, status: http?.statusCode ?? 0, etag: http?.value(forHTTPHeaderField: "ETag"))
    }
}
