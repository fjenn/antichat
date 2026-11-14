// AT-227 (queue order leg; R-227 AC2, E.2.4 step 6) + AT-201 part 3 / AT-203 (unit legs) — M2.T20: the first-run
// SetupInstaller over range-server.py. The starter is materialised before anything else is queued; the Evil variants
// enter the queue only after every Normal job is verified; the step-4 rows walk waiting → n % → Checking → Ready; the
// ModeSwitch readiness shows `evil.downloading` until the Evil model's view exists, then `evil.ready`.
// (Written as a Platform unit suite with the local range server instead of the XPC stub harness: the order lives in
// the coordinator, not the helper.)
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct EvilQueueOrderTests {
    final class Fixture: @unchecked Sendable {
        let dir: URL
        let server: RangeServer
        let catalog: ModelCatalog
        let models: ModelsDirectory
        init(slow: Int) throws {
            dir = DL.tempDir("setup")
            let sizes: [(String, Int64)] = [("fast.bin", 4), ("config.json", 1), ("tier.bin", 6), ("embed.bin", 2), ("evil.gguf", 4)]
            var bl: [String: DL.Blob] = [:]
            for (i, (n, mb)) in sizes.enumerated() {
                bl[n] = try DL.makeBlob(in: dir, name: n, size: mb * TransferConfig.mib + Int64(i * 811), seed: UInt64(300 + i))
            }
            server = try RangeServer(root: dir, args: ["--slow", "\(slow)"])
            let srv = server
            func file(_ n: String) -> [String: Any] {
                ["path": n.hasSuffix(".bin") ? "model.safetensors" : n, "size": bl[n]!.size, "sha256": bl[n]!.sha256, "sources": [srv.url(n).absoluteString]]
            }
            func model(_ engine: String, _ files: [String]) -> [String: Any] {
                ["role": "chat", "engine": engine, "format": engine == "llama.cpp" ? "gguf" : "mlx-safetensors", "capabilities": ["chat"],
                 "noncommercial_ok": true, "repo": "org/repo", "commit": String(repeating: "b", count: 40),
                 "footprint": ["weights_gb": 0.01, "kv_per_token_kb": 1, "overhead_gb": 0.1], "files": files.map(file)]
            }
            let json: [String: Any] = [
                "schema": 2, "catalog_version": 9, "issued": "2026-11-01T00:00:00Z", "expires": "2027-11-01T00:00:00Z", "min_app_version": "0.0.1",
                "revoked": [], "roles": ["chat_fast"], "tone_sentence": "", "assignments": [:] as [String: Any],
                "models": ["fast": model("mlx-swift-lm", ["config.json", "fast.bin"]), "tier": model("mlx-swift-lm", ["config.json", "tier.bin"]),
                           "embed": model("mlx-swift-lm", ["embed.bin"]), "evil": model("llama.cpp", ["evil.gguf"])],
            ]
            catalog = try ModelCatalog.decode(try JSONSerialization.data(withJSONObject: json))
            models = ModelsDirectory(root: dir.appending(path: "Models"))
            try models.create()
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        /// Items the way InstallQueue.plan builds them (each sha256 once, priority = position).
        func items() -> (normal: InstallPlan, evil: [InstallPlan.Item]) {
            var seen = Set<String>(), prio = 0
            func item(_ id: String, _ pack: ModelPack, _ mode: ModelMode, _ role: String, group: String) -> InstallPlan.Item {
                let m = catalog.models[id]!
                var reqs: [DownloadRequest] = []
                for f in m.files where seen.insert(f.sha256).inserted {
                    reqs.append(DownloadRequest(file: f, model: m, pack: group, priority: prio)); prio += 1
                }
                return .init(modelID: id, pack: pack, mode: mode, role: role, requests: reqs)
            }
            let plan = InstallPlan(stages: [
                .init(kind: .chatFast, items: [item("fast", .chat, .normal, "chat_fast", group: "chat")]),
                .init(kind: .chatEmbed, items: [item("tier", .chat, .normal, "chat", group: "chat"), item("embed", .chat, .normal, "embed", group: "chat")]),
            ])
            return (plan, [item("evil", .chat, .evil, "chat", group: "evil")])
        }
    }

    @Test func evilStartsOnlyAfterEveryNormalJobIsVerified() async throws {
        let fx = try Fixture(slow: 6000)
        let dl = DownloadCoordinator(models: fx.models, database: nil, config: TransferConfig(chunkSize: 2 * TransferConfig.mib), sleep: DL.fastSleep)
        let log = Notices()
        dl.observe { if case .state(let j) = $0 { log.add("\(j.request.modelID ?? "?"):\(j.state.rawValue)") } }
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        let installedLog = Notices()
        await setup.observe { ids in installedLog.add(ids.sorted().joined(separator: ",")) }
        let (plan, evil) = fx.items()
        let evilPlan = EvilPlan(extraBytes: evil.flatMap(\.requests).reduce(0) { $0 + $1.size }, availablePacks: [.chat],
                                unavailablePacks: [], requests: evil.flatMap(\.requests), items: evil)
        // Step 2 Continue → the Normal plan; step 3 Continue (Evil on) a moment later.
        let run = Task { await setup.start(plan, mayInstallNew: true, free: 500_000_000_000) }
        try await Task.sleep(for: .milliseconds(150))
        await setup.addEvil(evil)
        // ModeSwitch while the Evil files are not in: evil.downloading (queued until a throughput sample exists).
        let p0 = SetupProgress.compute(normal: plan.stages.flatMap(\.items), evil: evil, jobs: await dl.allJobs,
                                       present: { dl.blobs.contains($0) }, installed: await setup.installed)
        let r0 = EvilReadiness.state(enabled: true, plan: evilPlan, remainingBytes: p0.evilRemainingBytes, verifying: p0.evilVerifying, bytesPerSecond: nil)
        #expect(r0.copyKey == "evil.downloading.queued")
        #expect(EvilReadiness.state(enabled: true, plan: evilPlan, remainingBytes: p0.evilRemainingBytes, verifying: false,
                                    bytesPerSecond: 1_000_000).copyKey == "evil.downloading")
        #expect(await run.value == .enqueued(jobs: 4))
        // Wait for the whole queue (Normal, then Evil).
        for _ in 0..<600 {
            if await setup.installed.count == 4 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let events = log.all.compactMap { $0 }
        let lastNormalDone = try #require(events.lastIndex { $0 == "tier:done" || $0 == "embed:done" || $0 == "fast:done" })
        let firstEvil = try #require(events.firstIndex { $0.hasPrefix("evil:") })
        #expect(firstEvil > lastNormalDone, "\(events)")
        // The starter's view came first, before the tier model's.
        let firstInstalled = try #require(installedLog.all.compactMap { $0 }.first)
        #expect(firstInstalled == "fast", "\(installedLog.all)")
        #expect(await setup.installed == ["fast", "tier", "embed", "evil"])
        #expect(FileManager.default.fileExists(atPath: fx.models.install("evil").appending(path: "manifest.json").path))
        // Ready: every row, the hand-off target and the Evil line.
        let p1 = SetupProgress.compute(normal: plan.stages.flatMap(\.items), evil: evil, jobs: await dl.allJobs,
                                       present: { dl.blobs.contains($0) }, installed: await setup.installed)
        #expect(p1.rows.map(\.state) == [.ready, .ready])
        #expect(p1.starterReady && p1.tierReady && p1.tierPercent == 100)
        #expect(EvilReadiness.state(enabled: true, plan: evilPlan, remainingBytes: p1.evilRemainingBytes, verifying: p1.evilVerifying,
                                    bytesPerSecond: nil).copyKey == "evil.ready")
        ATLog.write("AT-227", "evil-queue-order.log", "SetupInstaller: \(events.joined(separator: " "))\ninstalled order: \(installedLog.all.compactMap { $0 })")
    }

    @Test func rowStatesWalkWaitingDownloadingCheckingReady() throws {
        let fx = try Fixture(slow: 0)
        let (plan, evil) = fx.items()
        let normal = plan.stages.flatMap(\.items)
        let fast = normal[0].requests, tier = normal[1].requests
        func job(_ r: DownloadRequest, _ s: DownloadJob.State, _ done: Int64, pause: DownloadJob.PauseReason? = nil) -> DownloadJob {
            DownloadJob(id: r.sha256, request: r, state: s, pauseReason: pause, bytesDone: done, retries: 0, errorKey: nil, createdAt: Date())
        }
        // Nothing queued: waiting; Evil row present.
        var p = SetupProgress.compute(normal: normal, evil: evil, jobs: [], present: { _ in false }, installed: [])
        #expect(p.rows.map(\.group) == ["chat", "evil"])
        #expect(p.rows.map(\.state) == [.waiting, .waiting])
        // Starter half done.
        p = SetupProgress.compute(normal: normal, evil: evil, jobs: [job(fast[1], .running, fast[1].size / 2)], present: { $0 == fast[0].sha256 },
                                  installed: [])
        guard case .downloading(let pct) = p.rows[0].state else { Issue.record("\(p.rows[0].state)"); return }
        #expect(pct > 0 && pct < 100)
        #expect(p.starterFraction > 0.4 && p.starterFraction < 1)
        // Starter verified + materialised: Open chat's moment; the chat row is still downloading the tier model.
        p = SetupProgress.compute(normal: normal, evil: evil, jobs: [job(tier[0], .running, 1)],
                                  present: { fast.map(\.sha256).contains($0) }, installed: ["fast"])
        #expect(p.starterReady && !p.tierReady)
        #expect(p.tierPercent < 100)
        // Every byte in, verifying: Checking.
        let all = Set(normal.flatMap(\.requests).map(\.sha256))
        p = SetupProgress.compute(normal: normal, evil: [], jobs: [], present: { all.contains($0) }, installed: ["fast"])
        #expect(p.rows[0].state == .checking)
        // System pause (no internet) and failure.
        p = SetupProgress.compute(normal: normal, evil: [], jobs: [job(tier[0], .paused, 10, pause: .system)], present: { fast.map(\.sha256).contains($0) },
                                  installed: ["fast"])
        #expect(p.rows[0].state == .paused)
        p = SetupProgress.compute(normal: normal, evil: [], jobs: [job(tier[0], .failed, 10)], present: { _ in false }, installed: [])
        #expect(p.rows[0].state == .failed)
        p = SetupProgress.compute(normal: normal, evil: [], jobs: [], present: { all.contains($0) }, installed: ["fast", "tier", "embed"])
        #expect(p.rows[0].state == .ready && p.readyCount == 1)
    }

    /// M2 review #7: pausing the starter row used to hold the rest of the setup forever (`wait` without `orPaused`):
    /// the tier model and the other stages are now enqueued once the starter is paused.
    @Test func pausedStarterStillQueuesTheRest() async throws {
        let fx = try Fixture(slow: 200)
        let dl = DownloadCoordinator(models: fx.models, database: nil, config: TransferConfig(chunkSize: 2 * TransferConfig.mib), sleep: DL.fastSleep)
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        let (plan, _) = fx.items()
        let run = Task { await setup.start(plan, mayInstallNew: true, free: 500_000_000_000) }
        var starter: DownloadJob?
        for _ in 0..<200 where starter == nil {
            starter = await dl.allJobs.first { $0.request.modelID == "fast" && $0.state == .running }
            try await Task.sleep(for: .milliseconds(10))
        }
        for j in await dl.allJobs where j.request.modelID == "fast" { await dl.pause(j.id) }
        let finished = Task { await run.value }
        var outcome: InstallQueue.Outcome?
        for _ in 0..<200 where outcome == nil {
            try await Task.sleep(for: .milliseconds(20))
            if await dl.allJobs.contains(where: { $0.request.modelID == "tier" }) { outcome = await finished.value }
        }
        #expect(outcome == .enqueued(jobs: 4))
        for j in await dl.allJobs { await dl.cancel(j.id) }
    }

    /// M2 review #9: Continue → Back → untick a pack → Continue: the dropped model stops downloading and its view is
    /// never written; files a kept model shares stay queued.
    @Test func untrackCancelsTheDroppedModelOnly() async throws {
        let fx = try Fixture(slow: 200)
        let dl = DownloadCoordinator(models: fx.models, database: nil, config: TransferConfig(chunkSize: 2 * TransferConfig.mib), sleep: DL.fastSleep)
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        let (plan, _) = fx.items()
        let run = Task { await setup.start(plan, mayInstallNew: true, free: 500_000_000_000) }
        for _ in 0..<200 where !(await dl.allJobs.contains { $0.request.modelID == "fast" }) { try await Task.sleep(for: .milliseconds(10)) }
        for j in await dl.allJobs where j.request.modelID == "fast" { await dl.pause(j.id) }  // let the rest enqueue
        _ = await run.value
        #expect(await setup.trackedIDs == ["fast", "tier", "embed"])
        let cancelled = await setup.untrack(["embed"])
        #expect(cancelled == 1)
        #expect(await setup.trackedIDs == ["fast", "tier"])
        let embedJobs = await dl.allJobs.filter { $0.request.modelID == "embed" }
        #expect(!embedJobs.isEmpty && embedJobs.allSatisfy { $0.state == .cancelled })
        #expect(await dl.allJobs.contains { $0.request.modelID == "tier" && $0.state != .cancelled })
        for j in await dl.allJobs { await dl.cancel(j.id) }
    }
}
