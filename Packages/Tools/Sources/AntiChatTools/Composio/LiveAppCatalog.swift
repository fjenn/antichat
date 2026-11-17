// Which apps Settings › Connections lists, kept current by every install itself: the relay's `GET /v1/toolkits`
// (what Composio offers right now; the relay holds the Composio key) merged with the bundled curated catalogue.
// Nobody publishes anything for this.
//   * The live list decides which apps exist: a new one appears, a removed one disappears. An app the user has
//     connected always stays, so it can be disconnected.
//   * An app the bundled catalogue has keeps its entry (hand-written summary, our categories, popular rank, bundled
//     logo). Any other app gets Composio's name, a summary derived from Composio's description (`AppSummary`), our
//     category for Composio's (`ComposioCatalog.categoryMap`; unknown = "other"), no popular rank, and its logo
//     from Composio's logo host (`AppLogoCache`), with its initial until that arrives.
//   * Left out, like tools/composio/build-catalog.py does for the bundled catalogue: the relay drops deprecated
//     toolkits, ones without tools, ones a person cannot sign in to and `x_mcp` duplicates; here, an app the
//     bundled catalogue does not have is dropped when it is on the exclude list, needs no sign-in, or says
//     "deprecated".
//   * `refresh`: one conditional request (`If-None-Match`), at most once a day; the last good answer is kept in
//     `<support>/Catalog/`. Never in Offline only. At launch and on the daily timer (`userOpened: false`) only
//     for an install with a Composio connection (the relay category is on from the first connected app,
//     MCPHost.addComposio, until the connection is removed) and its relay ID: an install that never connected an
//     app sends nothing by itself. When the user opens Settings › Connections, or a chat's Connect card looks an
//     app up (`userOpened: true`), the list is asked for either way: that is the user looking at connections, and
//     it is the request that creates the relay ID when there is none.
//   * A relay from before this route (404), any failure, or a stored list older than the bundled catalogue: the
//     newest of bundled / previously fetched keeps showing, silently.
// `ComposioCatalog.shared` reads `live?.catalog`; `DirectoryCatalogs.didChange` (kind `composio-catalog`) is posted on
// the main thread when the list of apps changed.
import AntiChatFoundation
import AntiChatNetwork
import Foundation
import os

/// One app as the relay lists it (`relay/src/toolkits.ts`).
public struct RelayToolkit: Sendable, Equatable, Decodable {
    public var slug: String
    public var name: String
    public var description: String
    /// Composio's own category names.
    public var categories: [String]
    /// `oauth`, `apikey`, `other`, or `none` (no sign-in).
    public var auth: String
    /// Composio's logo URL, "" = none.
    public var logo: String

    public init(slug: String, name: String, description: String = "", categories: [String] = [], auth: String = "oauth", logo: String = "") {
        self.slug = slug; self.name = name; self.description = description; self.categories = categories; self.auth = auth; self.logo = logo
    }

    enum CodingKeys: String, CodingKey { case slug, name, description, categories, auth, logo }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        categories = (try? c.decodeIfPresent([String].self, forKey: .categories)) ?? []
        auth = (try? c.decodeIfPresent(String.self, forKey: .auth)) ?? "other"
        logo = (try? c.decodeIfPresent(String.self, forKey: .logo)) ?? ""
    }
}

public final class LiveAppCatalog: @unchecked Sendable {
    /// What one `refresh` came to.
    public enum Outcome: String, Sendable, Equatable {
        /// A list was stored (`updated`: the apps differ from before; `same`: they do not).
        case updated, same
        case notModified
        /// Checked less than a day ago: no request.
        case fresh
        case offline
        /// A background check for an install without a Composio connection: no request.
        case noInstall
        /// Old relay, network, bad body: the current catalogue stays.
        case failed
    }

    /// One `GET /v1/toolkits`; nil = 304. `userOpened`: see `refresh`.
    public typealias Fetch = @Sendable (_ etag: String?, _ userOpened: Bool) async throws -> (data: Data, etag: String?)?

    public static let kind = "composio-catalog"
    public static let maxBytes = 4 * 1024 * 1024
    public static let day: TimeInterval = 24 * 3600
    /// After a failed check, and while there is no usable list, the next one waits this long.
    public static let retry: TimeInterval = 3600

    /// The instance `ComposioCatalog.shared` and the logo views read (set by `start`).
    public static var live: LiveAppCatalog? {
        get { liveBox.withLock { $0 } }
        set { liveBox.withLock { $0 = newValue } }
    }
    private static let liveBox = OSAllocatedUnfairLock<LiveAppCatalog?>(initialState: nil)

    public let directory: URL
    public let logos: AppLogoCache
    private let bundled: ComposioCatalog
    /// What identifies the relay the stored list came from (another relay = no conditional request).
    private let source: String
    private let fetch: Fetch
    /// The install has a Composio connection: its relay ID exists and the relay category is on.
    private let hasConnection: @Sendable () -> Bool
    /// Not Offline only.
    private let online: @Sendable () -> Bool
    private let connected: @Sendable () -> Set<String>
    private let now: @Sendable () -> Date

    private struct Stored { var generated: String; var toolkits: [RelayToolkit] }
    private struct State {
        var list: Stored?
        /// The merged catalogue of `list` for `connected` (rebuilt when either changes).
        var merged: (connected: Set<String>, catalog: ComposioCatalog)?
        var lastFailure: Date?
        var running: Task<Outcome, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(directory: URL, source: String, bundled: ComposioCatalog = .bundled, fetch: @escaping Fetch,
                hasConnection: @escaping @Sendable () -> Bool,
                online: @escaping @Sendable () -> Bool = { !NetworkPolicyStore.shared.offlineOnly },
                connected: @escaping @Sendable () -> Set<String> = { ComposioApps.connected },
                now: @escaping @Sendable () -> Date = Date.init, logos: AppLogoCache? = nil) {
        self.directory = directory; self.source = source; self.bundled = bundled; self.fetch = fetch
        self.hasConnection = hasConnection; self.online = online; self.connected = connected; self.now = now
        self.logos = logos ?? AppLogoCache(directory: directory.appending(path: "Logos"))
    }

    public convenience init(directory: URL, relay: RelayClient = RelayClient(), bundled: ComposioCatalog = .bundled,
                            now: @escaping @Sendable () -> Date = Date.init, logos: AppLogoCache? = nil) {
        let policy = relay.session().policy
        self.init(directory: directory, source: relay.baseURL.absoluteString, bundled: bundled,
                  fetch: { try await relay.toolkits(etag: $0, userOpened: $1) },
                  hasConnection: { relay.hasInstallID && policy.isEnabled(.relay) },
                  online: { !policy.offlineOnly }, now: now, logos: logos)
    }

    // MARK: Reads

    /// The bundled catalogue merged with the live list; the bundled one alone while there is no usable list.
    public var catalog: ComposioCatalog {
        let connected = connected()
        return state.withLock { s in
            guard let list = s.list else { return bundled }
            if let m = s.merged, m.connected == connected { return m.catalog }
            let c = Self.merge(bundled: bundled, live: list.toolkits, connected: connected, generated: list.generated)
            s.merged = (connected, c)
            return c
        }
    }

    /// Whether the relay's list is in use (false = the bundled catalogue alone).
    public var isLive: Bool { state.withLock { $0.list != nil } }

    // MARK: Launch

    /// Makes an instance `live`, loads the list stored before, then checks now and every day at background
    /// priority, only for an install with a Composio connection. No relay in this build = nothing at all.
    @discardableResult
    public static func start(directory: URL, interval: Duration = .seconds(24 * 3600)) -> Task<Void, Never>? {
        guard RelayClient.isAvailable() else { return nil }
        let catalog = LiveAppCatalog(directory: directory)
        live = catalog
        return Task.detached(priority: .background) {
            await catalog.loadCached()
            while !Task.isCancelled {
                await catalog.refresh(userOpened: false)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Takes the stored list when it is still readable and not older than the bundled catalogue.
    public func loadCached() async {
        guard let data = try? Data(contentsOf: fileURL), let list = Self.decode(data, today: now()) else { return }
        if install(list) { await announce() }
    }

    // MARK: Refresh

    /// Checks the relay when the last check is a day old (`force`: now). `userOpened` false (launch, the daily
    /// timer) = only for an install with a Composio connection; true = the user opened Connections or a Connect
    /// card. Never throws; the outcome is for logs and tests.
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
        return outcome
    }

    private func check(userOpened: Bool, force: Bool) async -> Outcome {
        guard online() else { return .offline }
        guard userOpened || hasConnection() else { return .noInstall }
        var seen = loadSeen()
        if seen?.source != source { seen = nil }
        let t = now()
        let (usable, lastFailure) = state.withLock { ($0.list != nil, $0.lastFailure) }
        if !force {
            if let f = lastFailure, t.timeIntervalSince(f) < Self.retry { return .fresh }
            if let at = seen?.checkedAt, t.timeIntervalSince(at) < (usable ? Self.day : Self.retry), t >= at { return .fresh }
        }
        let answer: (data: Data, etag: String?)?
        do {
            // Not modified only means something while the list it refers to is the one in use.
            answer = try await fetch(usable ? seen?.etag : nil, userOpened)
        } catch {
            if NetworkGate.map(error) != nil { return .offline }
            state.withLock { $0.lastFailure = t }
            return .failed
        }
        guard let answer else {
            saveSeen(Seen(source: source, etag: seen?.etag, checkedAt: t))
            return .notModified
        }
        guard answer.data.count <= Self.maxBytes, let list = Self.decode(answer.data, today: t) else {
            state.withLock { $0.lastFailure = t }
            AppLog.log(.catalog, .error, "apps: the relay's list was refused (\(answer.data.count) bytes)")
            return .failed
        }
        let changed = install(list)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try answer.data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.log(.catalog, .error, "apps: the list could not be stored: \(error)")
        }
        saveSeen(Seen(source: source, etag: answer.etag, checkedAt: t))
        state.withLock { $0.lastFailure = nil }
        if changed {
            AppLog.log(.catalog, .info, "apps: \(list.toolkits.count) from the relay (\(list.generated))")
            await announce()
        }
        return changed ? .updated : .same
    }

    /// Uses `list` unless the bundled catalogue is newer. True = the apps shown changed.
    private func install(_ list: Stored) -> Bool {
        guard String(list.generated.prefix(10)) >= bundled.generated else { return false }
        return state.withLock { s in
            let changed = s.list?.toolkits != list.toolkits
            s.list = list
            if changed { s.merged = nil }
            return changed
        }
    }

    private func announce() async {
        await MainActor.run {
            NotificationCenter.default.post(name: DirectoryCatalogs.didChange, object: self, userInfo: ["kind": Self.kind])
        }
    }

    // MARK: Files

    var fileURL: URL { directory.appending(path: "relay-toolkits.json") }
    private var seenURL: URL { directory.appending(path: "relay-toolkits-state.json") }

    private struct Seen: Codable { var source: String; var etag: String?; var checkedAt: Date }

    private func loadSeen() -> Seen? {
        (try? Data(contentsOf: seenURL)).flatMap { try? JSONDecoder().decode(Seen.self, from: $0) }
    }

    private func saveSeen(_ seen: Seen) {
        guard let data = try? JSONEncoder().encode(seen) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: seenURL, options: .atomic)
    }

    // MARK: The relay's answer

    /// The relay's body, when it is one: a time that is not in the future and at least one app with a linkable
    /// slug (rows with another slug, and second rows of a slug, are dropped).
    private static func decode(_ data: Data, today: Date) -> Stored? {
        struct File: Decodable { let generated: String; let toolkits: [RelayToolkit] }
        guard let f = try? JSONDecoder().decode(File.self, from: data), f.toolkits.count <= 50_000,
              DirectoryCatalogs.isDay(String(f.generated.prefix(10)), today: today) else { return nil }
        var seen = Set<String>()
        let rows = f.toolkits.filter { DirectoryCatalogs.isSlug($0.slug) && seen.insert($0.slug).inserted }
        return rows.isEmpty ? nil : Stored(generated: f.generated, toolkits: rows)
    }

    // MARK: Merge

    /// The catalogue to show: see the head of this file. `generated` = when the relay read the list.
    public static func merge(bundled: ComposioCatalog, live: [RelayToolkit], connected: Set<String> = [],
                             generated: String = "") -> ComposioCatalog {
        var apps: [ComposioCatalog.App] = []
        var seen = Set<String>()
        for t in live where DirectoryCatalogs.isSlug(t.slug) && !seen.contains(t.slug) {
            if let curated = bundled.app(t.slug) {
                apps.append(curated)
            } else if let app = app(t, in: bundled) {
                apps.append(app)
            } else {
                continue
            }
            seen.insert(t.slug)
        }
        for slug in connected.sorted() where DirectoryCatalogs.isSlug(slug) && !seen.contains(slug) {
            let known = ComposioApps.known.first { $0.slug == slug }?.title
            apps.append(bundled.app(slug) ?? .init(slug: slug, name: known ?? slug.replacingOccurrences(of: "_", with: " ").capitalized,
                                                   categories: ["other"]))
        }
        var categories = bundled.categories
        for id in ["other"] where !categories.contains(where: { $0.id == id }) && apps.contains(where: { $0.categories.contains(id) }) {
            categories.append(.init(id: id, title: "Other"))
        }
        return ComposioCatalog(categories: categories, apps: apps, generated: generated.isEmpty ? bundled.generated : generated,
                               categoryMap: bundled.categoryMap, excluded: bundled.excluded)
    }

    /// The entry of an app the bundled catalogue does not have; nil = not shown.
    static func app(_ t: RelayToolkit, in bundled: ComposioCatalog) -> ComposioCatalog.App? {
        guard !bundled.excluded.contains(t.slug), t.auth != "none",
              !(t.name + " " + t.description).lowercased().contains("deprecated") else { return nil }
        let name = displayName(t.name, slug: t.slug)
        return .init(slug: t.slug, name: name, summary: AppSummary.derive(name: name, description: t.description),
                     categories: [category(t.categories, map: bundled.categoryMap)], popular: nil,
                     logoURL: AppLogoCache.logoURL(t.logo))
    }

    /// Composio's name without a trailing " MCP"; the slug's words when there is none.
    static func displayName(_ name: String, slug: String) -> String {
        let n = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let cut = n.range(of: #"\s+MCP$"#, options: .regularExpression).map { String(n[..<$0.lowerBound]) } ?? n
        let out = cut.isEmpty ? n : cut
        return out.isEmpty ? slug.replacingOccurrences(of: "_", with: " ").capitalized : String(out.prefix(80))
    }

    /// Our category for Composio's: the first of its names the map files somewhere other than "other".
    static func category(_ names: [String], map: [String: String]) -> String {
        names.lazy.compactMap { map[$0.trimmingCharacters(in: .whitespaces).lowercased()] }.first { $0 != "other" } ?? "other"
    }
}
