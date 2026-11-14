// M1.T18 AT-233 (2) + (1) on a real model: a 200-turn scripted user side on chat-9b-q4 (MLX, through the real
// XPC helper), context 16K, 2–5 s gaps between turns.
//   make test-integration-real TIER=T1 FILTER=CompactionSoakTests      (GPU: run under lockf /tmp/antichat-gpu.lock)
// Pass: every idle compaction starts at ≥ 75 % (and at least one ran and succeeded); turns that waited on a
// compaction before their request (synchronous fallback at 85 %, or an idle run still in flight) ≤ 5 % (≤ 10 of
// 200); after the soak every original message row is unchanged (sha256 of its parts as finished = as stored now),
// summary rows cover prefixes of the path, and FTS finds the first (summarised) user turn.
// Artefact: build/at/AT-233/soak.json (repo-relative, next to this source). Skipped unless ANTICHAT_TIER=T1.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB
import XCTest

final class CompactionSoakTests: XCTestCase {
    static let turns = Int(ProcessInfo.processInfo.environment["ANTICHAT_SOAK_TURNS"] ?? "") ?? 200
    static let window = 16_384

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static let topics = [
        "lighthouses", "sourdough bread", "tidal pools", "the history of the bicycle", "honeybees", "glaciers",
        "chess openings", "medieval castles", "coral reefs", "the printing press", "volcanoes", "jazz standards",
        "migratory birds", "paper making", "the Silk Road", "tea ceremonies", "comets", "wind turbines",
        "origami", "desert plants",
    ]
    static let asks = [
        "Tell me about %@ in about 150 words.", "Give me five surprising facts about %@, one sentence each.",
        "Explain how %@ work or worked, in two short paragraphs.", "Write a short story (about 120 words) involving %@.",
        "What would a beginner get wrong about %@? Answer in under 150 words.",
    ]

    /// Turn i's user prompt (deterministic; turn 0 carries a unique code word for the FTS check).
    static func prompt(_ i: Int) -> String {
        let topic = topics[i % topics.count]
        let ask = String(format: asks[(i / topics.count) % asks.count], topic)
        return i == 0 ? "Codeword zebrafinch0001. " + ask : ask
    }

    struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    func testSoak200Turns() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] == "T1" else {
            throw XCTSkip("ANTICHAT_TIER must be T1 (make test-integration-real TIER=T1)")
        }
        let dir = PrefixReuseTests.view("chat-9b-q4")
        guard FileManager.default.fileExists(atPath: dir.path) else { throw XCTSkip("chat-9b-q4 not fetched") }
        let slot = ModelSlot(engine: .mlx, key: "chat-9b-q4", path: dir.path, contextTokens: Self.window)
        let client = EngineClient(appBuild: "it-compaction-soak")
        try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: UInt64(9.5e9)))
        if let err = await client.warmup(slot) { throw err }
        defer { client.disconnect() }

        let db = try AppDatabase.inMemory()
        let chatID = StorageID.make()
        let policy = ContextPolicy(windowOverride: Self.window)
        let controller = TurnController(
            chatID: chatID, database: db, engine: client, sampling: Sampling(temperature: 0.6, topP: 0.95, maxTokens: 512, seed: 7),
            contextPolicy: policy) { slot }
        let updates = UpdateBox()
        let listener = Task { for await u in controller.updates { updates.append(u) } }
        defer { listener.cancel() }

        var rng = LCG(state: 0x5eed)
        var rows: [[String: Any]] = []
        var bodyHash: [String: String] = [:]
        var parent: String?
        var firstUser: String?
        let started = ContinuousClock.now
        for i in 0..<Self.turns {
            let waitedBefore = await controller.compaction.waitedTurns
            let u = StorageID.make(), a = StorageID.make()
            if i == 0 { firstUser = u }
            let sent = ContinuousClock.now
            await controller.start(.send(userID: u, text: Self.prompt(i), parentID: parent), assistantID: a)
            let accepted = ContinuousClock.now
            let result = try await updates.finished(a, timeout: .seconds(240))
            let done = ContinuousClock.now
            let waited = await controller.compaction.waitedTurns > waitedBefore
            let usage = updates.lastUsage(for: a)
            parent = a
            for id in [u, a] { bodyHash[id] = try Self.hash(id, db) }
            rows.append([
                "turn": i + 1, "status": result.status.rawValue, "waited_on_compaction": waited,
                "fraction_at_send": usage?.fraction ?? -1, "prompt_tokens_est": usage?.tokens ?? -1,
                "reply_chars": result.text.count, "start_s": Self.secs(accepted - sent), "turn_s": Self.secs(done - sent),
            ])
            if i % 10 == 0 { print("soak turn \(i + 1): \(String(format: "%.0f", (usage?.fraction ?? 0) * 100))% waited=\(waited)") }
            if i + 1 < Self.turns { try await Task.sleep(for: .seconds(2 + 3 * rng.next())) }
        }
        // Let a last idle compaction finish (or not start) before checking the store.
        try await Task.sleep(for: .seconds(3))
        let runs = await controller.compaction.runs
        let waitedTurns = await controller.compaction.waitedTurns

        // (1) Originals unchanged, summaries cover prefixes, FTS finds the summarised first turn.
        var changed: [String] = []
        for (id, h) in bodyHash where try Self.hash(id, db) != h { changed.append(id) }
        let summaries = try db.read { try ChatMessageAdapter.summaryNodes(chatID: chatID, db: $0) }
        let path = try db.read { db in try ChatMessageAdapter.turns(MessageTree.visiblePath(chatID, db: db), db: db).map(\.id) }
        let summariesValid = summaries.allSatisfy { node in
            node.coveredIDs.allSatisfy { bodyHash[$0] != nil }
        }
        let latestValid = summaries.first.map { ChatMessageAdapter.isValid($0.coveredIDs, for: path) } ?? false
        let ftsHit = try FTSSearch(db).search("zebrafinch0001").first?.messageID
        let idleRuns = runs.filter { $0.trigger == .idle }
        let syncRuns = runs.filter { $0.trigger == .sync }
        let idleOK = !idleRuns.filter(\.ok).isEmpty && idleRuns.allSatisfy { $0.fractionBefore >= policy.idleThreshold }
        let bound = Int((Double(Self.turns) * 0.05).rounded(.down))
        let pass = changed.isEmpty && summariesValid && latestValid && ftsHit == firstUser && idleOK && waitedTurns <= bound
        let report: [String: Any] = [
            "at": "AT-233", "pass": pass, "model": "chat-9b-q4 (MLX, XPC helper)", "window": Self.window,
            "turns": Self.turns, "gap_s": "2–5 (seeded LCG)", "wall_s": Self.secs(ContinuousClock.now - started),
            "waited_turns": waitedTurns, "waited_bound": bound, "idle_threshold": policy.idleThreshold,
            "sync_threshold": policy.syncThreshold,
            "runs": runs.map { r -> [String: Any] in
                ["trigger": r.trigger.rawValue, "fraction_before": r.fractionBefore, "fraction_after": r.fractionAfter ?? -1,
                 "covered_turns": r.coveredTurns, "ok": r.ok, "error": r.error ?? "", "seconds": r.seconds]
            },
            "idle_runs": idleRuns.count, "idle_ok": idleRuns.filter(\.ok).count, "sync_runs": syncRuns.count,
            "originals_checked": bodyHash.count, "originals_changed": changed.count, "summary_rows": summaries.count,
            "summaries_cover_originals": summariesValid, "latest_summary_valid_for_path": latestValid,
            "fts_first_turn_hit": ftsHit == firstUser, "per_turn": rows,
        ]
        let rel = "build/at/AT-233/soak.json"
        let out = Self.repoRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        XCTAssertTrue(changed.isEmpty, "original rows changed: \(changed.count)")
        XCTAssertTrue(summariesValid && latestValid, "summary rows do not cover the path")
        XCTAssertEqual(ftsHit, firstUser, "FTS did not find the summarised first turn")
        XCTAssertTrue(idleOK, "idle compaction: \(idleRuns)")
        XCTAssertLessThanOrEqual(waitedTurns, bound, "turns that waited on compaction")
    }

    static func hash(_ id: String, _ db: AppDatabase) throws -> String {
        try db.read { db in
            var h = SHA256()
            for p in try MessageRepository.parts(of: id, db: db) { h.update(data: Data("\(p.idx):\(p.kind.rawValue):\(p.body)|".utf8)) }
            let m = try MessageRecord.fetchOne(db, key: id)
            h.update(data: Data("\(m?.role.rawValue ?? "")|\(m?.parentID ?? "")".utf8))
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}

/// Thread-safe update log for the soak.
final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TurnUpdate] = []

    struct Timeout: Error { var id: String }

    func append(_ u: TurnUpdate) { lock.lock(); items.append(u); lock.unlock() }

    func snapshot() -> [TurnUpdate] { lock.lock(); defer { lock.unlock() }; return items }

    func finished(_ id: String, timeout: Duration) async throws -> TurnResult {
        let deadline = ContinuousClock.now + timeout
        while true {
            for u in snapshot() where u.assistantID == id { if case .finished(let r) = u.kind { return r } }
            if ContinuousClock.now > deadline { throw Timeout(id: id) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The usage the request of turn `id` carried (emitted when the request was built).
    func lastUsage(for id: String) -> ContextUsage? {
        for u in snapshot().reversed() where u.assistantID == id {
            if case .context(.usage(let usage)) = u.kind { return usage }
        }
        return nil
    }
}
