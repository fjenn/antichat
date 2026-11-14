// M1.T20 definition of done: every guard of IncognitoGuards.swift has a test (guard numbers as in its header),
// plus IncognitoSession's lifecycle and an end-to-end turn that leaves the app container byte-identical.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct IncognitoGuardsTests {
    private func tempDir(_ tag: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("incognito-\(tag)-\(UUID().uuidString)",
                                                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func appEnvironment(_ db: AppDatabase, script: String = words(3, delayMs: 1),
                                settings: PromptSettings = PromptSettings()) throws -> ChatEnvironment {
        let engine = InProcessScriptedEngine(script: try EngineScript(text: script))
        return ChatEnvironment(database: db, engine: engine, promptSettings: settings,
                               tools: ToolRuntime(registry: .m1(scriptedTools: false), permissions: ToolPermissionStore(db)),
                               slot: { .scripted("inline") })
    }

    /// Every file under `root` with its size and modification date.
    private func listing(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        while let u = e?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out[u.path] = "\(v?.fileSize ?? -1)@\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return out
    }

    // MARK: Guard 1 — store

    @Test func guard1StoreIsInMemoryOnly() throws {
        let root = tempDir("g1")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try AppDatabase.onDisk(at: root.appendingPathComponent("antichat.sqlite"))
        #expect(throws: IncognitoGuards.Refusal.persistentStore) { try IncognitoGuards.store(disk) }
        let s = try IncognitoSession(app: try appEnvironment(disk), tempRoot: root)
        defer { s.discard() }
        #expect(try IncognitoGuards.store(s.store) === s.store)
        #expect(s.environment.database === s.store)
        #expect(s.environment.isIncognito)
    }

    // MARK: Guard 2 — files

    @Test func guard2FilesStayInTheSessionTempDirectory() throws {
        let root = tempDir("g2")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try IncognitoSession(app: try appEnvironment(try AppDatabase.inMemory()), tempRoot: root)
        let inside = s.tempDirectory.appendingPathComponent("xfer/frame.png")
        #expect(try IncognitoGuards.fileLocation(inside, session: s) == inside)
        #expect(throws: IncognitoGuards.Refusal.diskOutput) {
            try IncognitoGuards.fileLocation(root.appendingPathComponent("Media/x.png"), session: s)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: s.tempDirectory.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
        s.discard()
        #expect(!FileManager.default.fileExists(atPath: s.tempDirectory.path))
    }

    /// A second "launch" sweep while a session is alive keeps every incognito dir it owns (the session's, the intake's
    /// attachments, xfer and outputs all carry its pid); a dir whose owner has exited is swept.
    @Test func guard2LaunchSweepKeepsLiveOwnersAndSweepsDeadOnes() throws {
        let root = tempDir("g2live")
        defer { try? FileManager.default.removeItem(at: root) }
        let live = IncognitoTemp.make("attachments", in: root)
        let dead = IncognitoTemp.make("dead", in: root)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        try Data("\(p.processIdentifier)".utf8).write(to: dead.appendingPathComponent(IncognitoTemp.ownerFile))
        let removed = IncognitoSession.sweepStaleTempDirectories(in: root)
        #expect(removed.map(\.lastPathComponent) == [dead.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: live.path), "the live session's dir stays")
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        // The intake's incognito root is created owned by this process.
        let intake = AttachmentIntake.incognitoRoot()
        defer { try? FileManager.default.removeItem(at: intake) }
        #expect(IncognitoTemp.isLive(intake))
        #expect(intake.lastPathComponent.hasPrefix(IncognitoSession.tempPrefix))
    }

    @Test func guard2LaunchSweepRemovesStaleDirectoriesOnly() throws {
        let root = tempDir("g2s")
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(IncognitoSession.tempPrefix + "stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let other = root.appendingPathComponent("keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        // A directory owned by a live process that is not this one (launchd, pid 1) is left alone.
        let foreign = root.appendingPathComponent(IncognitoSession.tempPrefix + "foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: foreign.appendingPathComponent(".owner"))
        let removed = IncognitoSession.sweepStaleTempDirectories(in: root)
        #expect(removed.map(\.lastPathComponent) == [stale.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    /// fix/selection-hang: a shared $TMPDIR full of other suites' leftovers (359k entries on the dev Mac) blocked the
    /// app's launch 25–40 s in this sweep. The sweep builds nothing for an entry outside our prefix, removes only real
    /// directories of this user (not a symlink or a file that carries the prefix), and stays fast with 10k foreign entries.
    @Test func launchSweepReadsOnlyOurPrefix() throws {
        let root = tempDir("g2big")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for i in 0..<10_000 { fm.createFile(atPath: root.appendingPathComponent("fileout-tests-\(i)").path, contents: nil) }
        for n in ["a", "b", "c"] {
            try fm.createDirectory(at: root.appendingPathComponent(IncognitoSession.tempPrefix + n), withIntermediateDirectories: true)
        }
        let target = root.appendingPathComponent("not-ours", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent(IncognitoSession.tempPrefix + "link"), withDestinationURL: target)
        fm.createFile(atPath: root.appendingPathComponent(IncognitoSession.tempPrefix + "file").path, contents: Data("x".utf8))

        var scanned = 0
        let names = IncognitoTemp.matchingNames(in: root, scanned: &scanned)
        #expect(scanned >= 10_000 + 6)
        #expect(Set(names) == Set(["a", "b", "c", "link", "file"].map { IncognitoSession.tempPrefix + $0 }), "only our prefix is returned")

        let t0 = Date()
        let removed = IncognitoSession.sweepStaleTempDirectories(in: root)
        let took = Date().timeIntervalSince(t0)
        #expect(Set(removed.map(\.lastPathComponent)) == Set(["a", "b", "c"].map { IncognitoSession.tempPrefix + $0 }))
        #expect(fm.fileExists(atPath: target.path), "a symlink's target is never followed")
        #expect((try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent(IncognitoSession.tempPrefix + "link").path)) != nil)
        #expect(fm.fileExists(atPath: root.appendingPathComponent(IncognitoSession.tempPrefix + "file").path))
        #expect(took < 1, "sweep over 10k foreign entries took \(took) s")
    }

    /// The work per launch is capped: 70 stale dirs go in two launches (64 + 6).
    @Test func launchSweepIsCappedPerLaunch() throws {
        let root = tempDir("g2cap")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<70 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(IncognitoSession.tempPrefix + "s\(i)"),
                                                    withIntermediateDirectories: true)
        }
        #expect(IncognitoSession.sweepStaleTempDirectories(in: root).count == IncognitoSession.sweepLimit)
        #expect(IncognitoSession.sweepStaleTempDirectories(in: root).count == 70 - IncognitoSession.sweepLimit)
    }

    /// The launch entry point returns at once and sweeps on a background task; the app's `init` calls only it.
    @Test func launchSweepNeverBlocksTheCaller() async throws {
        let root = tempDir("g2async")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<10_000 { FileManager.default.createFile(atPath: root.appendingPathComponent("router-\(i)").path, contents: nil) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(IncognitoSession.tempPrefix + "stale"),
                                                withIntermediateDirectories: true)
        let done = AsyncStream<[URL]>.makeStream()
        let t0 = Date()
        IncognitoSession.scheduleLaunchSweep(in: root, done: { done.continuation.yield($0); done.continuation.finish() })
        #expect(Date().timeIntervalSince(t0) < 0.05, "the launch call returned only after \(Date().timeIntervalSince(t0)) s")
        var removed: [URL] = []
        for await r in done.stream { removed = r }
        #expect(removed.map(\.lastPathComponent) == [IncognitoSession.tempPrefix + "stale"])
        // App/AntiChat/AntiChatApp.swift's init schedules the sweep; it never runs it on the main thread.
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/AntiChat/AntiChatApp.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        #expect(source.contains("IncognitoSession.scheduleLaunchSweep("))
        #expect(!source.contains("IncognitoSession.sweepStaleTempDirectories("))
    }

    @Test func guard2PasteBlobsStayInMemory() throws {
        let root = tempDir("g2p")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try IncognitoSession(app: try appEnvironment(try AppDatabase.inMemory()), tempRoot: root)
        defer { s.discard() }
        let a = try s.environment.pastes.save(text: String(repeating: "secret ", count: 2_000), displayName: "Pasted text",
                                              messageID: nil)
        let blob = try #require(try AttachmentRepository(s.store).blob(id: a.blobID))
        #expect(blob.path.hasPrefix("memory:"))
        #expect((try FileManager.default.contentsOfDirectory(atPath: s.tempDirectory.path)).allSatisfy { $0 == ".owner" })
    }

    // MARK: Guard 3 — drafts

    @Test func guard3NoDraftsForIncognitoChats() throws {
        let app = try appEnvironment(try AppDatabase.inMemory())
        let s = try IncognitoSession(app: app, tempRoot: tempDir("g3"))
        defer { s.discard() }
        let id = try s.createChat()
        #expect(!IncognitoGuards.allowsDraft(chatID: id, router: app.stores))
        #expect(IncognitoGuards.allowsDraft(chatID: "some-disk-chat", router: app.stores))
        #expect(IncognitoGuards.allowsDraft(chatID: nil, router: app.stores))
    }

    // MARK: Guard 4 — titles

    @Test func guard4NoTitleForIncognito() throws {
        let app = try appEnvironment(try AppDatabase.inMemory())
        let s = try IncognitoSession(app: app, tempRoot: tempDir("g4"))
        defer { s.discard() }
        #expect(IncognitoGuards.allowsTitle(app))
        #expect(!IncognitoGuards.allowsTitle(s.environment))
    }

    // MARK: Guard 5 — KV slots (every request flagged)

    @Test func guard5EveryRequestIsFlaggedIncognito() async throws {
        let app = try appEnvironment(try AppDatabase.inMemory())
        let s = try IncognitoSession(app: app, tempRoot: tempDir("g5"))
        defer { s.discard() }
        let plain = ChatRequest(modelSlot: .scripted("inline"), messages: [ChatMessage(role: .user, content: "hi")])
        #expect(IncognitoGuards.allowsSlotSave(plain))
        #expect(!IncognitoGuards.allowsSlotSave(IncognitoGuards.flag(plain)))
        let chatID = try s.createChat()
        let controller = s.environment.controller(chatID: chatID)
        let log = UpdateLog(controller)
        let a = StorageID.make()
        await controller.start(.send(userID: StorageID.make(), text: "hello", parentID: nil, attachmentIDs: []), assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        #expect(s.engine.requestCount >= 1)
        #expect(s.engine.lastRequest?.incognito == true)
        #expect(await controller.lastRequest?.incognito == false)  // the controller's own copy; the wrapper flags it
    }

    // MARK: Guard 6 — network

    @Test func guard6NoNetworkActivityRows() {
        #expect(!IncognitoGuards.allowsNetworkActivityRecord(incognito: true))
        #expect(IncognitoGuards.allowsNetworkActivityRecord(incognito: false))
    }

    // MARK: Guard 7 — logs

    @Test func guard7LogRedactionWhileASessionIsOpen() async throws {
        // The process-wide count is shared with other suites that open sessions in parallel, so this checks the
        // session's own share (begun once, ended exactly once) rather than absolute counts (flaked under --parallel).
        let s = try IncognitoSession(app: try appEnvironment(try AppDatabase.inMemory()), tempRoot: tempDir("g7"))
        #expect(s.holdsLogRedaction && AppLog.openIncognitoSessions >= 1)
        #expect(IncognitoGuards.logRedactionActive)
        s.discard()
        #expect(!s.holdsLogRedaction)
        s.discard()  // idempotent: one end per begin
        #expect(!s.holdsLogRedaction)
        let inTask = await AppLog.$incognito.withValue(true) { AppLog.isRedacting }
        #expect(inTask)
    }

    // MARK: Guard 8 — diagnostics

    @Test func guard8DiagnosticsDropIncognitoFields() throws {
        let app = try appEnvironment(try AppDatabase.inMemory())
        let s = try IncognitoSession(app: app, tempRoot: tempDir("g8"))
        defer { s.discard() }
        let id = try s.createChat()
        let payload = ["chat.\(id).lastError": "engine.restarted", "chat.disk-1.lastError": "x", "current": id, "build": "dev"]
        let out = IncognitoGuards.diagnostics(payload, excluding: app.stores)
        #expect(out == ["chat.disk-1.lastError": "x", "build": "dev"])
    }

    // MARK: Guard 9 — media jobs

    @Test func guard9MediaJobsThatPersistAreRefused() throws {
        #expect(throws: IncognitoGuards.Refusal.diskOutput) { try IncognitoGuards.checkMediaJob(persistsOutput: true, incognito: true) }
        try IncognitoGuards.checkMediaJob(persistsOutput: false, incognito: true)
        try IncognitoGuards.checkMediaJob(persistsOutput: true, incognito: false)
    }

    // MARK: Guard 10 — window state

    @Test func guard10WindowNotRestorable() {
        #expect(!IncognitoGuards.windowIsRestorable(showingIncognito: true))
        #expect(IncognitoGuards.windowIsRestorable(showingIncognito: false))
    }

    // MARK: Guard 11 — memory / personalization (read-only)

    @Test func guard11PersonalizationIsReadOnlyAndUnpersonalizedDropsIt() async throws {
        let settings = PromptSettings(PromptInputs(personalization: Personalization(aboutYou: "I keep bees in Lisbon."),
                                                   memorySnapshot: "Likes figs."))
        let app = try appEnvironment(try AppDatabase.inMemory(), settings: settings)
        let s = try IncognitoSession(app: app, tempRoot: tempDir("g11"))
        defer { s.discard() }
        #expect(s.personalization == .personalized)
        #expect(s.environment.promptSettings.isReadOnly)
        #expect(s.environment.promptSettings.inputs.personalization.aboutYou == "I keep bees in Lisbon.")
        s.environment.promptSettings.update { $0.memorySnapshot = "written by incognito" }
        #expect(settings.inputs.memorySnapshot == "Likes figs.")
        #expect(s.setPersonalization(.unpersonalized))
        #expect(s.environment.promptSettings.inputs.personalization == .none)
        #expect(s.environment.promptSettings.inputs.memorySnapshot.isEmpty)

        // The rendered request: no instruction layer for Unpersonalized.
        let chatID = try s.createChat()
        let controller = s.environment.controller(chatID: chatID)
        let log = UpdateLog(controller)
        let a = StorageID.make()
        await controller.start(.send(userID: StorageID.make(), text: "hello", parentID: nil, attachmentIDs: []), assistantID: a)
        _ = try await log.waitFinished(a)
        let layers = (s.engine.lastRequest?.messages ?? []).compactMap { item -> String? in
            if case .layer(let l) = item { return l.content } else { return nil }
        }.joined()
        #expect(!layers.contains("Lisbon"))
        #expect(!layers.contains("figs"))
        // After the first message the choice is locked.
        #expect(!s.setPersonalization(.personalized))
    }

    @Test func guard11PersonalizedIncludesTheLayer() async throws {
        let settings = PromptSettings(PromptInputs(personalization: Personalization(aboutYou: "I keep bees in Lisbon.")))
        let s = try IncognitoSession(app: try appEnvironment(try AppDatabase.inMemory(), settings: settings), tempRoot: tempDir("g11p"))
        defer { s.discard() }
        let chatID = try s.createChat()
        let controller = s.environment.controller(chatID: chatID)
        let log = UpdateLog(controller)
        let a = StorageID.make()
        await controller.start(.send(userID: StorageID.make(), text: "hello", parentID: nil, attachmentIDs: []), assistantID: a)
        _ = try await log.waitFinished(a)
        let layers = (s.engine.lastRequest?.messages ?? []).compactMap { item -> String? in
            if case .layer(let l) = item { return l.content } else { return nil }
        }.joined()
        #expect(layers.contains("Lisbon"))
    }

    // MARK: Guard 12 — unread

    @Test func guard12NoUnreadFlagForIncognito() throws {
        let app = try appEnvironment(try AppDatabase.inMemory())
        let s = try IncognitoSession(app: app, tempRoot: tempDir("g12"))
        defer { s.discard() }
        let id = try s.createChat()
        #expect(!IncognitoGuards.allowsUnreadFlag(chatID: id, router: app.stores))
        #expect(IncognitoGuards.allowsUnreadFlag(chatID: "disk", router: app.stores))
    }

    // MARK: End to end (NFR-PR3 at the unit level)

    @Test func aTurnInIncognitoLeavesTheContainerUntouched() async throws {
        let root = tempDir("e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("AntiChat", isDirectory: true)
        let disk = try AppDatabase.onDisk(at: container.appendingPathComponent("antichat.sqlite"))
        let app = try appEnvironment(disk, script: words(20, delayMs: 1))
        // Settle the WAL of the open itself.
        _ = try disk.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat") }
        let before = listing(container)
        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let s = try IncognitoSession(app: app, tempRoot: tempRoot)
        let chatID = try s.createChat()
        let card = try s.environment.pastes.save(text: "quillfeather " + String(repeating: "x", count: 12_000),
                                                 displayName: "Pasted text", messageID: nil)
        let controller = s.environment.controller(chatID: chatID)
        let log = UpdateLog(controller)
        let a = StorageID.make()
        await controller.start(.send(userID: StorageID.make(), text: "zephyrquartz", parentID: nil,
                                     attachmentIDs: [card.id]), assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        #expect(app.stores.isEphemeral(chatID))
        #expect(app.stores.database(for: chatID) === s.store)
        #expect(try ChatRepository(disk).chat(chatID) == nil)
        #expect(try ChatRepository(s.store).chat(chatID) != nil)
        #expect(s.hasContent)
        s.discard()
        #expect(!app.stores.isEphemeral(chatID))
        #expect(!s.hasContent)
        #expect(listing(container) == before)
        #expect(!FileManager.default.fileExists(atPath: s.tempDirectory.path))
        let onDisk = try disk.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? -1 }
        #expect(onDisk == 0)
    }
}
