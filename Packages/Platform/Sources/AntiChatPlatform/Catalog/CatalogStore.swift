// M2.T05 (R-220 AC1/AC3/AC4, NFR-SEC7, NFR-SEC2; blueprint E §E.2.2, §E.2.6; architecture §7.1 fail-closed).
// The one owner of the model catalog:
//   * at launch: the cached last-good catalog (Catalog/catalog.json + .sig, re-verified), else the bundled
//     baseline (Resources/catalog-baseline.json + .sig), so first launch and offline launches always have one;
//   * `refresh()` (gate category `.catalog`, background priority; at launch and every 24 h): GET catalog.json +
//     catalog.json.sig, verify (key A or B), reject `catalog_version` below the high-water mark (rollback), accept an
//     expired catalog with a warning (installed models keep working, nothing new installs), write the cache
//     atomically and the `catalog_state` row;
//   * any failure (network, bad signature, rollback, schema) keeps the last good catalog. A bad signature also
//     stops new installs (`catalog.badSignature`) until a good catalog arrives.
// `isLoadable(id)` is false for a `disable`-revoked id; `mayInstallNew` gates every install entry point.
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import Foundation
import os

public final class CatalogStore: @unchecked Sendable {
    public enum Source: String, Sendable, Codable { case fetched, cache, baseline, none }
    public enum Status: String, Sendable, Codable, Equatable {
        case ok, expired, badSignature, rollback, schema, network, offline
    }
    public struct Snapshot: Sendable, Equatable {
        public var catalog: ModelCatalog?
        public var source: Source
        public var status: Status
        public var highWater: Int
        /// M7.T01 (R-253): the bytes of `catalog`, present only when they passed the verifier, so a consumer of another
        /// catalog section (search engines) reads the same verified document and keeps the last good one on a bad
        /// signature. Not part of equality.
        public var verifiedData: Data? = nil
        public static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.catalog == b.catalog && a.source == b.source && a.status == b.status && a.highWater == b.highWater
        }
    }

    public typealias Fetch = @Sendable (URL) async throws -> Data
    public static let didChange = Notification.Name("AntiChatCatalogStoreDidChange")
    /// Engines this app build can run, with their version (E.2.2 `engine` + `engine_min`).
    public static let engineVersions: [String: String] = [
        "mlx-swift-lm": "1.0.0", "llama.cpp": "1.0.0", "coreml": "1.0.0", "sd.cpp": "1.0.0", "fastmetal": "1.0.0", "onnx": "1.0.0",
        "accelerate": "1.0.0",  // ChildSafetyCheck age bins (A-M4-T02b)
        "ltx-2-mlx": "1.0.0",  // M5.T07 (A-M5-04): LTX-2.3 with sound, in the video runtime
    ]

    public let url: URL
    public let cacheDirectory: URL
    private let database: AppDatabase?
    private let verifier: CatalogVerifier
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let baseline: (data: Data, sig: Data)?
    private let state = OSAllocatedUnfairLock(initialState: Snapshot(catalog: nil, source: .none, status: .ok, highWater: 0))
    private var badSignatureLatched: Bool { state.withLock { $0.status == .badSignature } }

    public init(url: URL, cacheDirectory: URL, database: AppDatabase?, verifier: CatalogVerifier = CatalogVerifier(),
                baseline: (data: Data, sig: Data)? = CatalogStore.bundledBaseline(), now: @escaping @Sendable () -> Date = Date.init,
                fetch: @escaping Fetch = CatalogStore.gatedFetch) {
        self.url = url; self.cacheDirectory = cacheDirectory; self.database = database; self.verifier = verifier
        self.fetch = fetch; self.now = now; self.baseline = baseline
        loadLastGood()
    }

    // MARK: Reads

    public var snapshot: Snapshot { state.withLock { $0 } }
    public var catalog: ModelCatalog? { snapshot.catalog }

    /// New installs are allowed only from a verified, unexpired catalog, and never right after a bad signature.
    public var mayInstallNew: Bool {
        let s = snapshot
        guard let c = s.catalog, s.status != .badSignature else { return false }
        return !c.isExpired(at: now())
    }

    /// False for an id the current catalog does not know, a `disable`-revoked id, or an engine this build cannot run.
    public func isLoadable(_ id: String) -> Bool {
        guard let c = catalog, let m = c.models[id] else { return false }
        if c.revocation(for: id)?.action == .disable { return false }
        return Self.isCompatible(m)
    }

    /// The `warn` notice for an id, if any (`disable` is reported by `isLoadable`).
    public func warning(for id: String) -> CatalogRevocation? {
        catalog?.revocation(for: id).flatMap { $0.action == .warn ? $0 : nil }
    }

    /// E.2.2 engine compatibility: an entry for an unknown engine or a newer `engine_min` is skipped.
    public static func isCompatible(_ m: CatalogModel) -> Bool {
        guard let have = engineVersions[m.engine] else { return false }
        guard let need = m.engineMin else { return true }
        return have.compare(need, options: .numeric) != .orderedAscending
    }

    // MARK: Refresh

    /// Fetches, verifies and (when it passes) installs the remote catalog. Never throws: the outcome is the status.
    @discardableResult
    public func refresh() async -> Status {
        let data: Data, sig: Data
        do {
            data = try await fetch(url)
            sig = try await fetch(URL(string: url.absoluteString + ".sig")!)
        } catch {
            return finish(NetworkGate.map(error) != nil ? .offline : .network)
        }
        guard verifier.verify(data: data, sig: sig) else {
            AppLog.log(.catalog, .error, "catalog: signature does not verify; keeping the last good catalog")
            return finish(.badSignature)
        }
        let fetched: ModelCatalog
        do { fetched = try ModelCatalog.decode(data) } catch {
            AppLog.log(.catalog, .error, "catalog: schema rejected (\(error)); keeping the last good catalog")
            return finish(.schema)
        }
        let current = snapshot
        if fetched.catalogVersion < current.highWater || (fetched.catalogVersion == current.highWater && fetched != current.catalog) {
            AppLog.log(.catalog, .error, "catalog: version \(fetched.catalogVersion) ≤ high-water \(current.highWater) rejected (rollback)")
            return finish(.rollback)
        }
        if fetched.catalogVersion > current.highWater || current.source == .baseline {
            do { try writeCache(data: data, sig: sig) } catch {
                AppLog.log(.catalog, .error, "catalog: cache write failed: \(error)")
            }
        }
        let status: Status = fetched.isExpired(at: now()) ? .expired : .ok
        state.withLock { $0 = Snapshot(catalog: fetched, source: .fetched, status: status, highWater: max($0.highWater, fetched.catalogVersion), verifiedData: data) }
        persistState(fetchedAt: now())
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return status
    }

    /// Refreshes now, then every `interval` (24 h) at background priority, until the task is cancelled.
    public func startSchedule(interval: Duration = .seconds(24 * 3600)) -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: Internals

    private func finish(_ status: Status) -> Status {
        state.withLock { s in
            // A bad signature latches until a good catalog arrives; other failures leave an expired/ok status as it was.
            if status == .badSignature || status == .rollback || status == .schema { s.status = status }
            else if s.status != .badSignature { s.status = (s.catalog?.isExpired(at: now()) ?? false) ? .expired : s.status }
        }
        persistState(fetchedAt: nil)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return status
    }

    var cacheURL: URL { cacheDirectory.appending(path: "catalog.json") }
    var cacheSigURL: URL { cacheDirectory.appending(path: "catalog.json.sig") }

    private func writeCache(data: Data, sig: Data) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Signature first, catalog last: a crash in between leaves a pair that fails verification → baseline.
        try sig.write(to: cacheSigURL, options: .atomic)
        try data.write(to: cacheURL, options: .atomic)
    }

    private func loadLastGood() {
        let record = database.flatMap { try? CatalogStateRecord.load($0) }
        var highWater = record?.highWater ?? 0
        if let data = try? Data(contentsOf: cacheURL), let sig = try? Data(contentsOf: cacheSigURL),
           verifier.verify(data: data, sig: sig), let c = try? ModelCatalog.decode(data) {
            highWater = max(highWater, c.catalogVersion)
            let status: Status = record?.status == Status.badSignature.rawValue ? .badSignature : (c.isExpired(at: now()) ? .expired : .ok)
            let snap = Snapshot(catalog: c, source: .cache, status: status, highWater: highWater, verifiedData: data)
            state.withLock { $0 = snap }
        } else if let b = baseline, verifier.verify(data: b.data, sig: b.sig), let c = try? ModelCatalog.decode(b.data) {
            highWater = max(highWater, c.catalogVersion)
            let status: Status = record?.status == Status.badSignature.rawValue ? .badSignature : (c.isExpired(at: now()) ? .expired : .ok)
            let snap = Snapshot(catalog: c, source: .baseline, status: status, highWater: highWater, verifiedData: b.data)
            state.withLock { $0 = snap }
        } else {
            AppLog.log(.catalog, .error, "catalog: neither cache nor baseline verifies; nothing can be installed")
            let snap = Snapshot(catalog: nil, source: .none, status: .badSignature, highWater: highWater)
            state.withLock { $0 = snap }
        }
    }

    private func persistState(fetchedAt: Date?) {
        guard let database else { return }
        let s = snapshot
        let old = try? CatalogStateRecord.load(database)
        // The baseline stays in the app bundle (never copied out: an offline launch writes nothing, AT-NFR-PR3).
        let record = CatalogStateRecord(highWater: s.highWater, lastGoodPath: s.source == .baseline ? "bundle:catalog-baseline.json" : cacheURL.path,
                                        fetchedAt: fetchedAt ?? old?.fetchedAt, expiresAt: s.catalog?.expires, status: s.status.rawValue)
        if record != old { try? record.save(database) }
    }

    // MARK: Defaults

    /// The bundled baseline pair (`Resources/catalog-baseline.json` + `.sig`), verified like any other catalog.
    public static func bundledBaseline() -> (data: Data, sig: Data)? {
        guard let d = Bundle.module.url(forResource: "catalog-baseline", withExtension: "json", subdirectory: "Resources"),
              let s = Bundle.module.url(forResource: "catalog-baseline.json", withExtension: "sig", subdirectory: "Resources"),
              let data = try? Data(contentsOf: d), let sig = try? Data(contentsOf: s) else { return nil }
        return (data, sig)
    }

    /// GET through the gate (category `.catalog`): Offline only and the category switch apply, and the request is
    /// recorded in Network activity.
    public static let gatedFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await NetworkGate.gated(.catalog).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// `-CatalogURL <url>` (Debug) → `Endpoints.plist` `CatalogURL` in the app bundle → the dev default.
    public static func endpoint(options: LaunchOptions = .current, bundle: Bundle = .main) -> URL {
        if let s = options.catalogURL, let u = URL(string: s) { return u }
        if let u = Endpoints.url("CatalogURL", bundle: bundle) { return u }  // M10: Debug → CatalogURLDev
        return URL(string: "http://localhost:4321/catalog/v2/catalog.json")!
    }
}

/// The copy key Settings › Capabilities shows for a catalog status (`CatalogStatusBanner`); nil = nothing to show.
public enum CatalogStatusCopy {
    public static func key(_ s: CatalogStore.Status) -> String? {
        switch s {
        case .expired: "catalog.expired"
        case .badSignature: "catalog.badSignature"
        default: nil
        }
    }
}
