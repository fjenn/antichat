// AT-262 (R-262 AC1; M7.T13 steps 1–3): progressive disclosure with 40 installed skills, 30 ScriptedEngine turns per
// tier T0–T4, every prompt dumped (`PromptDump`, build/at/AT-262/prompts/<tier>/). Each turn the script loads the
// selector's top two skills (`load_skill` ×2 in one step). Per dump: at most M(tier) `name: description` lines; no
// skill body before a `load_skill` call (or the T0 `skill_preload` event, then only that body); every loaded body ≤ the
// tier's body budget; skills used per turn ≤ the tier's max. Plus: the stable prefix hash is the same for every turn of
// a chat although the manifest changes (R-230/R-269 with skills on), and auto-activation off = explicit only.
import AntiChatEngineProtocol
import AntiChatFoundation
@testable import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import Foundation
import Synchronization
import Testing

@Suite(.serialized) struct SkillDisclosureTests {
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    static let fixtures: URL = {
        if let e = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !e.isEmpty { return URL(fileURLWithPath: e) }
        return repo.appendingPathComponent("fixtures")
    }()

    /// Deterministic hashing embedder (64 dims, token bag): similar words → similar vectors, no model.
    static let fakeSelector = SkillSelector(embed: { texts, _ in texts.map(SkillDisclosureTests.vector) })

    static func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: 64)
        for t in text.lowercased().split(whereSeparator: { !$0.isLetter }) where t.count >= 3 {
            var h: UInt64 = 1469598103934665603
            for b in t.prefix(5).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % 64)] += 1
        }
        return v
    }

    static func marker(_ name: String) -> String { "BODY-MARK-\(name)" }

    /// The 20 activation skills + 20 more (long bodies past every tier's budget), each body carrying its marker.
    static func installForty(into store: SkillStore, scratch: URL) throws {
        let src = fixtures.appendingPathComponent("skills/activation-20")
        var folders: [(String, String)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: src.path).sorted() where !name.hasPrefix(".") {
            let md = try String(contentsOf: src.appendingPathComponent("\(name)/SKILL.md"), encoding: .utf8)
            folders.append((name, md + "\n\(marker(name))\n"))
        }
        let topics = ["astronomy", "chess", "knitting", "pottery", "sailing", "beekeeping", "calligraphy", "origami", "fishing",
                      "birdwatching", "cycling", "climbing", "photography", "woodworking", "baking", "aquarium", "camping",
                      "genealogy", "podcasting", "skating"]
        for (i, t) in topics.enumerated() {
            let name = "hobby-\(t)"
            let long = String(repeating: "Step \(i): practise \(t) carefully and write down what you learn.\n", count: 400)
            folders.append((name, "---\nname: \(name)\ndescription: Coaching for \(t) beginners and hobbyists. Use when the user asks about \(t).\n---\n\n# \(t)\n\(marker(name))\n\(long)"))
        }
        #expect(folders.count == 40)
        for (name, md) in folders {
            let dir = scratch.appendingPathComponent("src-\(UUID().uuidString)/\(name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try md.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try SkillImporter.install(try SkillImporter.inspect(dir), into: store)
        }
    }

    static func prompts() throws -> [String] {
        try String(contentsOf: fixtures.appendingPathComponent("prompts/skills-activation-100.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["prompt"] as? String
            }
    }

    struct Env {
        let database: AppDatabase
        let store: SkillStore
        let scratch: URL
        init() throws {
            database = try AppDatabase.inMemory()
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent("skill-disclosure-\(UUID().uuidString)", isDirectory: true)
            store = SkillStore(root: scratch.appendingPathComponent("Skills"), database: database)
            try SkillDisclosureTests.installForty(into: store, scratch: scratch)
        }
        func controller(tier: DeviceTier, script: String, selector: SkillSelector? = SkillDisclosureTests.fakeSelector,
                        chatID: String? = nil) throws -> (TurnController, String) {
            var runtime = ToolRuntime(registry: ToolRegistry([ScriptedTools.getTime()]), policy: .forTier(tier), selection: .off,
                                      tier: { tier })
            runtime.skills = store
            runtime.skillSelector = selector
            runtime.skillScripts = SkillScriptPolicy(fileToolsInstalled: { false }, runCodeEnabled: { false })
            let chat = try chatID ?? ChatRepository(database).create().id
            let c = TurnController(chatID: chat, database: database, engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                   tools: runtime) { .scripted("inline") }
            return (c, chat)
        }
        func cleanup() { try? FileManager.default.removeItem(at: scratch) }
    }

    static func loadScript(_ names: [String]) -> String {
        var lines: [String] = []
        for (i, n) in names.enumerated() {
            lines.append(#"{"t":"toolCallDone","id":"call_\#(i + 1)","name":"load_skill","args":"{\"name\":\"\#(n)\"}","delayMs":1}"#)
        }
        lines += [#"{"t":"turn"}"#, #"{"t":"textDelta","v":"Done.","delayMs":1}"#]
        return lines.joined(separator: "\n")
    }

    @Test(arguments: DeviceTier.allCases) func testDisclosurePerTier(_ tier: DeviceTier) async throws {
        let e = try Env()
        defer { e.cleanup() }
        let b = try #require(TierBudgets.shared.skills)
        let m = b.candidatesM[tier.rawValue]!, maxActive = b.maxActive[tier.rawValue]!, budget = b.bodyTokens[tier.rawValue]!
        let dumpDir = Self.repo.appendingPathComponent("build/at/AT-262/prompts/\(tier.rawValue)")
        try? FileManager.default.removeItem(at: dumpDir)
        let all = e.store.list()
        // 27 fixture prompts + 3 that hit the long-bodied skills (the truncation path).
        let prompts = Array(try Self.prompts().prefix(27))
            + ["How do I start knitting a scarf as a knitting beginner?", "Astronomy tips for beginners with a small telescope",
               "How do I start beekeeping in my garden as a beekeeping hobbyist?"]
        var preloads = 0, loads = 0, truncated = 0, manifestLines = 0
        for p in prompts {
            let top = await Self.fakeSelector.topM(p, candidates: all.filter { $0.record.enabled }, m: 2, store: e.store).map(\.name)
            let (c, _) = try e.controller(tier: tier, script: Self.loadScript(top))
            let log = UpdateLog(c)
            let a = StorageID.make()
            await PromptDump.$taskDirectory.withValue(dumpDir.path) {
                await c.start(.send(userID: StorageID.make(), text: p, parentID: nil), assistantID: a)
            }
            _ = try await log.waitFinished(a)
            let dump = try String(contentsOf: dumpDir.appendingPathComponent("\(a).txt"), encoding: .utf8)
            // ≤ M description lines.
            let listed = SkillManifestBlock.names(in: dump)
            #expect(listed.count <= m, "\(tier) \(listed.count) > M \(m)")
            manifestLines += listed.count
            // No body before load_skill, except the announced pre-load.
            let preloaded = dump.split(separator: "\n").filter { $0.hasPrefix("skill_preload ") }
                .compactMap { $0.split(separator: " ").first { $0.hasPrefix("name=") }.map { String($0.dropFirst(5)) } }
            #expect(preloaded.count <= 1)
            if !preloaded.isEmpty { #expect(tier == .t0, "pre-load only on T0 by default"); preloads += 1 }
            for s in all where !preloaded.contains(s.name) {
                #expect(!dump.contains(Self.marker(s.name)), "\(tier): body of \(s.name) in the prompt before load_skill")
            }
            // Loaded bodies within the tier budget; skills used ≤ max_active.
            let tools = (await c.lastRequest?.messages ?? []).compactMap { item -> ChatMessage? in
                if case .message(let msg) = item, msg.role == .tool, msg.toolName == LoadSkillTool.name { return msg } else { return nil }
            }
            for t in tools where t.content.hasPrefix("<skill name=") {
                loads += 1
                #expect(LoadSkillTool.estimateTokens(t.content) <= budget + 20, "\(tier): loaded body over \(budget) tokens")
                if t.content.contains("[Skill instructions shortened") { truncated += 1 }
            }
            let used = Set(log.all.filter { $0.assistantID == a }.compactMap { u -> String? in
                if case .activity(let act) = u.kind, act.kind == .skill { return act.tool } else { return nil }
            })
            #expect(used.count <= maxActive, "\(tier): \(used.count) skills used > max \(maxActive)")
            let refused = tools.filter { $0.content.contains("At most \(maxActive) skill") }
            if maxActive < 2, top.count == 2, preloaded.isEmpty { #expect(!refused.isEmpty, "\(tier): second load must be refused") }
        }
        #expect(loads > 0 && truncated > 0, "\(tier): loads \(loads), truncated \(truncated)")
        let summary = "AT-262 \(tier.rawValue): 30 turns, M=\(m) max_active=\(maxActive) body_tokens=\(budget); manifest lines total \(manifestLines), loads \(loads) (truncated \(truncated)), pre-loads \(preloads) — PASS\n"
        let log = Self.repo.appendingPathComponent("build/at/AT-262/summary-\(tier.rawValue).txt")
        try summary.write(to: log, atomically: true, encoding: .utf8)
    }

    @Test func testPrefixHashStableWithManifest() async throws {
        let e = try Env()
        defer { e.cleanup() }
        let chat = try ChatRepository(e.database).create().id
        var hashes = Set<String>(), manifests = Set<[String]>()
        for p in ["Plan five days in Lisbon for me", "Halve this cookie recipe please", "Write a haiku about snow"] {
            let (c, _) = try e.controller(tier: .t1, script: #"{"t":"textDelta","v":"ok","delayMs":1}"#, chatID: chat)
            let log = UpdateLog(c)
            let a = StorageID.make()
            await c.start(.send(userID: StorageID.make(), text: p, parentID: nil), assistantID: a)
            _ = try await log.waitFinished(a)
            hashes.insert(try #require(await c.lastPrompt).stableSHA256)
            manifests.insert(SkillManifestBlock.names(in: await c.lastRequest?.turnContext ?? ""))
        }
        #expect(hashes.count == 1, "the stable prefix must not change with the manifest")
        #expect(manifests.count == 3, "each request lists its own top skills")
    }

    @Test func testNoSelectorMeansExplicitOnly() async throws {
        let e = try Env()
        defer { e.cleanup() }
        let (c, _) = try e.controller(tier: .t1, script: #"{"t":"textDelta","v":"ok","delayMs":1}"#, selector: nil)
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "Plan five days in Lisbon", parentID: nil), assistantID: a)
        _ = try await log.waitFinished(a)
        #expect(!(await c.lastRequest?.turnContext ?? "").contains(SkillManifestBlock.open))
        #expect(!(await c.lastRequest?.tools ?? []).contains { $0.name == LoadSkillTool.name })
    }

    @Test func testManifestRendering() {
        let s = [SkillSelector.Scored(name: "b-skill", description: "Two\nlines", score: 0.4, semantic: true),
                 SkillSelector.Scored(name: "a-skill", description: "One", score: 0.9, semantic: true)]
        let text = SkillManifestBlock.render(s)
        #expect(text == "<available_skills>\n\(SkillManifestBlock.lead)\na-skill: One\nb-skill: Two lines\n</available_skills>")
        #expect(SkillManifestBlock.names(in: text) == ["a-skill", "b-skill"])
        #expect(SkillManifestBlock.render([]).isEmpty)
    }
}
