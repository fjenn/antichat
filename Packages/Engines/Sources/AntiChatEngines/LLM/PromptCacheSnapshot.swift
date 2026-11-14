// M2.T13 step 1 (R-206 AC2, NFR-M3): before the chat model steps aside for a media job, its KV prefix is saved, and
// restored when the model reloads at the next user message, so that turn does not re-prefill the whole chat.
//   MLX:          the prefix cache's session snapshots → `<kv>/<session>.safetensors` (mlx-swift-lm f5b0677
//                 `savePromptCache` / `loadPromptCacheSnapshot`, metadata: model key + tokens)
//   llama-server: the slot save it already does on session switch (`POST /slots/<id>?action=save`, `--slot-save-path`
//                 in the helper cache, LlamaSlotTable; M1.T20) — restored by the adapter when the session returns.
// Never for incognito chats (the session is marked at its first request; DoD). A snapshot written for another model
// (an update changed the slot, or a different chat model) is not restored; it is deleted once a day old (the folder is
// shared by every helper using these caches).
// M9.T05 (AT-236 AC3 IMAGE_TURN_OVERHEAD): the stable system prefixes too (system turn + tool schemas + the day's date
// line, MLXPrefixCache "prefix" snapshots). Before, only sessions were saved, so on T0–T2 — where every image job evicts
// the chat model — the first turn of any NEW chat after the reload (each picture request in a fresh chat) re-prefilled
// the whole stable prefix. Prefix files are content-addressed (`prefix-<model tag>-<prefix key>`), written only when
// absent (no I/O at a steady-state step-aside), kept across reloads (not one-use like sessions), and deleted once a day
// old (the date line has changed by then). One built by an incognito request is never written. Reuse stays exact-token
// only (`MLXPrefixCache.bestSnapshot`), so a file can never stand in for a different prompt.
import AntiChatFoundation
import CryptoKit
import Foundation
import MLXLMCommon

enum PromptCacheSnapshot {
    /// Another model's snapshot older than this is discarded on restore (shared kv folder).
    static let staleOtherModelAge: TimeInterval = 86_400
    static func url(_ dir: URL, session: UUID) -> URL { dir.appendingPathComponent("\(session.uuidString).safetensors") }

    /// Writes every persistable session of `cache` for `model`; returns the sessions written.
    @discardableResult
    static func save(_ cache: MLXPrefixCache, model: String, to dir: URL) -> [UUID] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [UUID] = []
        for (id, e) in cache.persistableSessions() {
            let meta = ["model": model, "tokens": e.tokens.map(String.init).joined(separator: ",")]
            do {
                try savePromptCache(url: url(dir, session: id), cache: e.cache, metadata: meta, state: e.state)
                out.append(id)
            } catch {
                AppLog.log(.engine, .error, "kv snapshot \(id) failed: \(error)")
            }
        }
        return out
    }

    /// Loads the snapshots of `model` back into `cache` and deletes them (one use); another model's are left for its
    /// helper unless a day old.
    @discardableResult
    static func restore(into cache: MLXPrefixCache, model: String, from dir: URL) -> [UUID] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [UUID] = []
        for f in files where f.pathExtension == "safetensors" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { continue }
            guard let snap = try? loadPromptCacheSnapshot(url: f) else { try? FileManager.default.removeItem(at: f); continue }
            guard snap.metadata["model"] == model else {
                // Another model's snapshot: the kv folder is shared by every helper using these caches, so it may be
                // another helper's pending restore. Discarded only once it is a day old (an update changed the slot).
                if let d = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(d) > staleOtherModelAge {
                    try? FileManager.default.removeItem(at: f)
                    AppLog.log(.engine, .info, "kv snapshot \(id) is for \(snap.metadata["model"] ?? "?"), not \(model): discarded")
                }
                continue
            }
            defer { try? FileManager.default.removeItem(at: f) }  // this model's: one use
            let tokens = (snap.metadata["tokens"] ?? "").split(separator: ",").compactMap { Int($0) }
            guard !tokens.isEmpty else { continue }
            cache.restoreSession(id, tokens: tokens, cache: snap.cache, state: snap.state)
            out.append(id)
        }
        return out
    }

    // MARK: - Stable prefixes (M9.T05)

    static let prefixFilePrefix = "prefix-"
    /// A stable prefix carries the day's date line: a file older than this can no longer match and is removed.
    static let stalePrefixAge: TimeInterval = 86_400

    /// First 12 hex chars of sha256(model): the file name says whose prefix it is without loading it.
    static func modelTag(_ model: String) -> String {
        SHA256.hash(data: Data(model.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func prefixURL(_ dir: URL, model: String, key: String) -> URL {
        dir.appendingPathComponent(prefixFilePrefix + modelTag(model) + "-" + key + ".safetensors")
    }

    /// Writes the persistable stable prefixes of `cache` for `model` that are not on disk yet; returns the keys written.
    @discardableResult
    static func savePrefixes(_ cache: MLXPrefixCache, model: String, to dir: URL) -> [String] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String] = []
        for (key, e) in cache.persistablePrefixes() {
            let u = prefixURL(dir, model: model, key: key)
            if FileManager.default.fileExists(atPath: u.path) { continue }  // content-addressed: already saved
            let meta = ["model": model, "kind": "prefix", "key": key, "tokens": e.tokens.map(String.init).joined(separator: ",")]
            do {
                try savePromptCache(url: u, cache: e.cache, metadata: meta, state: e.state)
                out.append(key)
            } catch {
                try? FileManager.default.removeItem(at: u)
                AppLog.log(.engine, .error, "kv prefix snapshot failed: \(error)")
            }
        }
        return out
    }

    /// Loads `model`'s stable prefixes (newest `limit`) back into `cache`; the files stay for the next reload. Any prefix
    /// file older than `stalePrefixAge` is removed (whoever wrote it), as is an unreadable or mislabelled one of `model`.
    @discardableResult
    static func restorePrefixes(into cache: MLXPrefixCache, model: String, from dir: URL, limit: Int = 4,
                                now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let tag = prefixFilePrefix + modelTag(model) + "-"
        var mine: [(URL, Date)] = []
        for f in files where f.pathExtension == "safetensors" && f.lastPathComponent.hasPrefix(prefixFilePrefix) {
            let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(d) > stalePrefixAge {
                try? fm.removeItem(at: f)
                continue
            }
            if f.lastPathComponent.hasPrefix(tag) { mine.append((f, d)) }
        }
        var out: [String] = []
        for (f, _) in mine.sorted(by: { $0.1 > $1.1 }).prefix(limit) {
            let key = String(f.deletingPathExtension().lastPathComponent.dropFirst(tag.count))
            guard let snap = try? loadPromptCacheSnapshot(url: f), snap.metadata["model"] == model,
                  snap.metadata["kind"] == "prefix", snap.metadata["key"] == key else {
                try? fm.removeItem(at: f)
                continue
            }
            let tokens = (snap.metadata["tokens"] ?? "").split(separator: ",").compactMap { Int($0) }
            guard !tokens.isEmpty else {
                try? fm.removeItem(at: f)
                continue
            }
            cache.restorePrefix(key, tokens: tokens, cache: snap.cache, state: snap.state)
            out.append(key)
        }
        return out
    }
}
