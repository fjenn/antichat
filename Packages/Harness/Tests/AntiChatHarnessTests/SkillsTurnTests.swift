// M7.T12 AT-082 in-process legs (the XCUITest legs in App/UITests/SkillsUITests.swift are pending Q-015):
// c2 explicit "/" use — the chip `skill:<name>` puts the skill's body in the prompt's `skills` layer and the reply
//    shows one "Using skill <name>" activity (`ToolActivity.Kind.skill`); "Turn off for this chat" (`skill.off:`) stops it;
// c3 per-chat switches never change the global row; Apply to every chat (off by default) applies a skill without a chip;
// c4 a skill turn makes zero NetworkGate requests (Offline only), and a skill whose allowed-tools want web search
//    carries `web|off` / `web|offline` on its activity line ("needs Web search (off)").
import AntiChatEngineProtocol
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct SkillsTurnTests {
    struct Env {
        let database: AppDatabase
        let store: SkillStore
        let chatID: String
        let controller: TurnController
        let log: UpdateLog
        let dir: URL
        /// The composer chips, set on the controller before the first send (deterministic: no detached Task).
        let chips: [String]

        init(toolsJSON: String? = nil, chips: [String] = [], extraSkill: (name: String, md: String)? = nil) throws {
            database = try AppDatabase.inMemory()
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-turn-\(UUID().uuidString)", isDirectory: true)
            store = SkillStore(root: dir, database: database)
            try StarterSkills.installIfNeeded(into: store)
            if let extra = extraSkill {
                let src = dir.deletingLastPathComponent().appendingPathComponent("src-\(UUID().uuidString)/\(extra.name)")
                try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
                try extra.md.write(to: src.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                try SkillImporter.install(try SkillImporter.inspect(src), into: store)
            }
            var runtime = ToolRuntime(registry: ToolRegistry([ScriptedTools.getTime()]), policy: .forTier(.t1), selection: .off, tier: { .t1 })
            runtime.skills = store
            chatID = try ChatRepository(database).create().id
            if let toolsJSON { _ = try ChatRepository(database).setToolsJSON(chatID, toolsJSON) }
            controller = TurnController(chatID: chatID, database: database,
                                        engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"Done.","delayMs":1}"#)),
                                        tools: runtime) { .scripted("inline") }
            log = UpdateLog(controller)
            self.chips = chips
        }

        func send(_ text: String = "Polish this: hi i want a refund") async throws -> String {
            let a = StorageID.make()
            if !chips.isEmpty, await controller.chips.isEmpty, await controller.lastRequest == nil { await controller.setChips(chips) }
            await controller.start(.send(userID: StorageID.make(), text: text, parentID: nil), assistantID: a)
            _ = try await log.waitFinished(a)
            return a
        }

        func skillsLayer() async -> String {
            let req = await controller.lastRequest
            return (req?.messages ?? []).compactMap { item -> String? in
                if case .layer(let l) = item, l.id == PromptLayerID.skills { return l.content } else { return nil }
            }.joined()
        }

        func skillLines(_ a: String) -> [ToolActivity] {
            var out: [String: ToolActivity] = [:]
            for u in log.all where u.assistantID == a { if case .activity(let t) = u.kind, t.kind == .skill { out[t.id] = t } }
            return out.values.sorted { $0.id < $1.id }
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func testSlashExplicitAndActivityLineTurnOff() async throws {
        let e = try Env(toolsJSON: #"["skill:email-polish"]"#)
        defer { e.cleanup() }
        let a = try await e.send()
        let layer = await e.skillsLayer()
        #expect(layer.hasPrefix("<skill name=\"email-polish\">"))
        #expect(layer.contains("# Email polish"))
        #expect(!layer.contains("meeting-notes"), "on but not picked and not Apply to every chat: not loaded")
        #expect(e.skillLines(a).map(\.tool) == ["email-polish"])
        #expect(e.skillLines(a).first?.result == nil, "no unmet needs")
        // Persisted with the reply (the line survives a relaunch).
        let parts = try MessageRepository(e.database).parts(of: a)
        #expect(ToolActivity.activities(in: parts).contains { $0.kind == .skill && $0.tool == "email-polish" })
        // "Turn off for this chat": the chip goes, the off marker stays → the next turn has no skill layer.
        _ = try ChatRepository(e.database).setToolsJSON(e.chatID, #"["skill.off:email-polish"]"#)
        let b = try await e.send()
        #expect(await e.skillsLayer().isEmpty)
        #expect(e.skillLines(b).isEmpty)
        #expect(try #require(e.store.skill(named: "email-polish")).record.enabled, "Settings unchanged")
    }

    /// The composer's chips reach the turn before the new chat's tools_json is saved.
    @Test func composerChipWithoutSavedToolsJSON() async throws {
        let e = try Env(chips: ["skill:meeting-notes"])
        defer { e.cleanup() }
        let a = try await e.send("notes: ship friday, ana does QA")
        #expect(await e.skillsLayer().contains("# Meeting notes"))
        #expect(e.skillLines(a).map(\.tool) == ["meeting-notes"])
        #expect(await e.controller.chips.isEmpty, "a skill chip forces no tool")
    }

    @Test func testPerChatToggleAndApplyAll() async throws {
        let e = try Env()
        defer { e.cleanup() }
        // Apply to every chat is off by default: nothing without a chip.
        #expect(e.store.list().allSatisfy { !$0.record.applyAll })
        _ = try await e.send()
        #expect(await e.skillsLayer().isEmpty)
        // On: applied in every chat without a chip…
        try e.store.setApplyAll("meeting-notes", true)
        let a = try await e.send()
        #expect(await e.skillsLayer().contains("# Meeting notes"))
        #expect(e.skillLines(a).map(\.tool) == ["meeting-notes"])
        // …except where this chat switched it off ("+" → Skills ›), which leaves the global row as it was.
        _ = try ChatRepository(e.database).setToolsJSON(e.chatID, #"["skill.off:meeting-notes"]"#)
        _ = try await e.send()
        #expect(await e.skillsLayer().isEmpty)
        let row = try #require(e.store.skill(named: "meeting-notes")).record
        #expect(row.enabled && row.applyAll)
        // A skill off in Settings, switched on for this chat only.
        try e.store.setApplyAll("trip-planner", true)
        #expect(try #require(e.store.skill(named: "trip-planner")).record.enabled == false)
        _ = try ChatRepository(e.database).setToolsJSON(e.chatID, #"["skill.off:meeting-notes","skill.on:trip-planner"]"#)
        _ = try await e.send("plan 3 days in Porto")
        #expect(await e.skillsLayer().contains("# Trip planner"))
        #expect(try #require(e.store.skill(named: "trip-planner")).record.enabled == false, "global switch unchanged")
    }

    @Test func testOfflineAndNeedsWebSearchOff() async throws {
        let md = "---\nname: web-helper\ndescription: Looks things up.\nallowed-tools: web_search\n---\nSearch first, then answer."
        let e = try Env(toolsJSON: #"["skill:web-helper","skill:email-polish"]"#, extraSkill: ("web-helper", md))
        defer { e.cleanup() }
        let requests = Mutex(0)
        let id = NetworkGate.addObserver { _ in requests.withLock { $0 += 1 } }
        defer { NetworkGate.removeObserver(id) }
        let policy = NetworkPolicyStore.shared
        let wasOffline = policy.offlineOnly
        policy.offlineOnly = true
        defer { policy.offlineOnly = wasOffline }
        let a = try await e.send()
        #expect(requests.withLock { $0 } == 0, "a skill turn makes no network request")
        let lines = e.skillLines(a)
        #expect(lines.map(\.tool) == ["email-polish", "web-helper"])
        let web = try #require(lines.first { $0.tool == "web-helper" })
        #expect(web.result == "web|offline")
        #expect(SkillNeeds.evaluate(allowedTools: ["web_search"], webSearch: .switchedOff) == [SkillNeed(feature: .webSearch, state: .off)])
        #expect(await e.skillsLayer().contains("Search first, then answer."), "the skill still applies; it says what it needs")
    }

    @Test func slashMenuListsSkillsAsAGroupForEveryModel() throws {
        let t = try Env()
        defer { t.cleanup() }
        var c = ComposerMenuContext(activeModelKey: "chat-0.8b")  // chat-only model: no tool entries (D-023)
        c.loadSkills(t.store)
        let items = SlashCommandRegistry.menuItems(c)
        let skills = items.filter { $0.group == .skills }
        #expect(skills.map(\.id) == ["skill:email-polish", "skill:meeting-notes"], "the two starters that are on")
        #expect(skills.allSatisfy { $0.makesChip })
        #expect(SlashCommandRegistry.addItems(c).contains { $0.id == "skills" }, "+ → Skills ›")
        #expect(!items.contains { $0.group == .tools })
    }
}
