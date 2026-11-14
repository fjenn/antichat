// M8.T08 (AT-091; R-091 AC1–AC4): the Privacy & Data page's rows and order, the statement byte-for-byte against the
// copy deck, the Network activity summary from seeded `network_activity` rows (per-category "last used", Offline
// only → all Paused), the location row (never requested until the user turns it on) and "New chats are incognito".
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct PrivacyDataViewModelTests {
    static let statement = "Your chats never leave this Mac unless you use an online feature. AntiChat never trains on your data and has no telemetry."

    private static var repoRoot: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }  // Packages/UI/Tests/AntiChatUIModuleTests/<file>
        return u
    }

    private func policy() -> NetworkPolicyStore {
        NetworkPolicyStore(defaults: .inMemory())
    }

    private func seed(_ db: AppDatabase, _ rows: [(TimeInterval, NetworkCategory, String)], now: Date) throws {
        try db.write { d in
            for (ago, cat, outcome) in rows {
                var r = NetworkActivityRecord(ts: now.addingTimeInterval(-ago), category: cat.rawValue, host: "\(cat.rawValue).example",
                                              bytes: 1200, outcome: outcome)
                try r.insert(d)
            }
        }
    }

    // MARK: AC1, AC4: statement and rows

    @Test func statementIsTheCopyDeckValueByteForByte() throws {
        #expect(PrivacyDataViewModel.statementKey.string() == Self.statement)
        let deck = try String(contentsOf: Self.repoRoot.appendingPathComponent("docs/research/10-architecture/design-system/copy-deck.md"),
                              encoding: .utf8)
        let line = try #require(deck.split(separator: "\n").first { $0.hasPrefix("| `privacy.statement`") })
        let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let value = try #require(cells.count > 2 ? cells[2] : nil)
        #expect(Array(value.utf8) == Array(PrivacyDataViewModel.statementKey.string().utf8))
    }

    @Test func rowsAreTheSettingsMapOrderAndCoverAC4() {
        let registry = SettingsRegistry.rows.filter { $0.section == .privacy }.map(\.id)
        #expect(registry == PrivacyDataViewModel.rowOrder)
        #expect(PrivacyDataViewModel.rowOrder == [
            "offlineOnly", "networkActivity", "privacyLocation", "newChatsIncognito", "incognitoPersonalizationDefault",
            "importChats", "exportAll", "restoreBackup", "archivedChats", "archiveAll", "deleteAll", "autoArchiveDays",
            "crashReports", "exportLogs",
        ])
        // R-091 AC4: incognito default, import, export, archive/delete all, crash reports opt-in, export logs.
        for id in ["newChatsIncognito", "importChats", "exportAll", "archiveAll", "deleteAll", "crashReports", "exportLogs"] {
            #expect(PrivacyDataViewModel.rowOrder.contains(id), "\(id)")
        }
        #expect(SettingsKeys.defaults["newChatsIncognito"] == "false")
        #expect(SettingsKeys.defaults["searchUsesLocation"] == "false")
        #expect(DeleteAllSheet.isConfirmed("DELETE") && !DeleteAllSheet.isConfirmed("delete"))
    }

    // MARK: AC2: network activity per category

    @Test func activitySummaryGivesLastUsedPerCategory() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let db = try AppDatabase.inMemory()
        try seed(db, [(5, .search, "ok"), (2 * 3600, .models, "ok"), (3 * 3600, .catalog, "ok"),
                      (60, .updates, "blocked"), (8 * 24 * 3600, .mcp, "ok")], now: now)
        let p = policy()
        let m = PrivacyDataViewModel(database: db, policy: p, now: { now })
        #expect(m.groups.map(\.group) == [.updates, .catalog, .search, .connections])  // no crash-report row until one was sent
        let byGroup = Dictionary(uniqueKeysWithValues: m.groups.map { ($0.group, $0) })
        #expect(PrivacyDataViewModel.lastUsedText(byGroup[.search]!.lastUsed, now: now) == "Last used just now")
        #expect(PrivacyDataViewModel.lastUsedText(byGroup[.catalog]!.lastUsed, now: now) == "Last used 2 hours ago")
        #expect(byGroup[.catalog]!.events.count == 2)
        #expect(byGroup[.updates]!.lastUsed == .never)  // a request the gate blocked did not leave the Mac
        #expect(byGroup[.updates]!.events.count == 1)  // …but it is listed
        #expect(byGroup[.connections]!.lastUsed == .never)  // outside the 7-day window and never recorded
        #expect(PrivacyDataViewModel.lastUsedText(.never, now: now) == "Never")
        #expect(byGroup[.search]!.state == .on)
        #expect(byGroup[.connections]!.state == .off)  // connections are off until the user adds one (M2 policy defaults)
        // State follows the gate's stored switch.
        p.setEnabled(.search, false)
        m.reload()
        #expect(m.groups.first { $0.group == .search }?.state == .off)
        #expect(PrivacyDataViewModel.stateLabel(.paused).string() == "Paused by Offline only")
    }

    @Test func offlineOnlyPausesEveryCategory() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let db = try AppDatabase.inMemory()
        try seed(db, [(30, .search, "ok")], now: now)
        let p = policy()
        p.offlineOnly = true
        let m = PrivacyDataViewModel(database: db, policy: p, now: { now })
        #expect(!m.groups.isEmpty)
        #expect(m.groups.allSatisfy { $0.state == .paused })
    }

    @Test func olderUseAndEventLimitAndCrashRow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let db = try AppDatabase.inMemory()
        try seed(db, (0..<25).map { (TimeInterval(100 + $0), NetworkCategory.relay, "ok") } + [(10, .crashReport, "ok")], now: now)
        let p = policy()
        p.recordUse(.updates, at: now.addingTimeInterval(-10 * 24 * 3600))
        let m = PrivacyDataViewModel(database: db, policy: p, now: { now })
        let byGroup = Dictionary(uniqueKeysWithValues: m.groups.map { ($0.group, $0) })
        #expect(PrivacyDataViewModel.lastUsedText(byGroup[.updates]!.lastUsed, now: now) == "More than 7 days ago")
        #expect(byGroup[.connections]!.events.count == NetworkActivitySummary.eventLimit)
        #expect(byGroup[.connections]!.events.first?.ts == now.addingTimeInterval(-100))  // newest first
        #expect(byGroup[.crashReports] != nil)  // shown once a report was sent
        #expect(m.groups.last?.group == .crashReports)
        #expect(PrivacyDataViewModel.outcomeLabel("ok").string() == "Done")
        #expect(PrivacyDataViewModel.outcomeLabel("weird").string() == "Failed")
    }

    /// The gate's own event path (NetworkActivityStore, what `NetworkGate.activitySink` calls) → the Web search row.
    @Test func aGateSearchEventShowsLastUsedJustNow() throws {
        let db = try AppDatabase.inMemory()
        NetworkActivityStore.write(NetworkEvent(category: .search, host: "html.duckduckgo.com", bytes: 4096, outcome: .ok,
                                                incognito: false), to: db)
        let m = PrivacyDataViewModel(database: db, policy: policy())
        let search = try #require(m.groups.first { $0.group == .search })
        #expect(PrivacyDataViewModel.lastUsedText(search.lastUsed, now: Date()) == "Last used just now")
        #expect(search.events.map(\.host) == ["html.duckduckgo.com"])
    }

    @Test func emptyDatabaseShowsNeverEverywhere() throws {
        let m = PrivacyDataViewModel(database: try AppDatabase.inMemory(), policy: policy())
        #expect(m.groups.allSatisfy { $0.lastUsed == .never && $0.events.isEmpty })
        #expect(CopyKey("set.privacy.activity.empty").string() == "No network activity in the last 7 days")
    }

    // MARK: AC3: location

    @Test func locationIsNotRequestedUntilTheUserTurnsItOn() {
        let location = LocationPermission(system: .fake(.notDetermined), observeActivation: false)
        #expect(location.requestCount == 0)
        #expect(SearchLocationRow.notice(enabled: false, status: .notDetermined, asked: false) == nil)
        location.request()  // the explainer's [Continue]
        #expect(location.requestCount == 1)
        #expect(location.status == .notDetermined)  // the dialog is left unanswered
        #expect(SearchLocationRow.notice(enabled: true, status: location.status, asked: true) == CopyKey("perm.location.waiting"))
    }

    @Test func deniedLocationOffersSystemSettings() {
        let opened = LockedURLs()
        let location = LocationPermission(system: .fake(.notDetermined, answer: .denied, opened: { opened.append($0) }),
                                          observeActivation: false)
        location.request()
        #expect(location.status == .denied)
        #expect(location.status.needsSystemSettings)
        #expect(SearchLocationRow.notice(enabled: true, status: .denied, asked: true) == CopyKey("perm.location.denied"))
        #expect(SearchLocationRow.notice(enabled: true, status: .servicesOff, asked: false) == CopyKey("perm.location.servicesOff"))
        #expect(SearchLocationRow.notice(enabled: true, status: .granted, asked: true) == nil)
        location.openSystemSettings()
        #expect(opened.urls == [URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!])
        #expect(CopyKey("perm.location.why").string().hasPrefix("AntiChat uses your approximate location only"))
    }

    // MARK: AC4: "New chats are incognito"

    @Test func newChatsIncognitoOpensAnIncognitoChat() throws {
        let engine = InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"x"}"#))
        let env = ChatEnvironment(database: try AppDatabase.inMemory(), engine: engine, slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        state.makeIncognito = { [sessions] in try sessions.makeIncognitoSession() }
        state.onIncognitoClosed = { [weak sessions] in sessions?.incognitoClosed($0) }
        let flag = LockedFlag()
        state.newChatsIncognito = { flag.value }
        state.incognitoPersonalizationDefault = { .unpersonalized }
        state.activate()
        state.newChat()
        #expect(state.route == .newChat)
        flag.value = true
        state.newChat()
        #expect(state.isIncognito)
        #expect(state.incognitoPersonalization == .unpersonalized)
        state.toggleIncognito()  // the toolbar button still leaves incognito
        #expect(state.route == .newChat)
        state.newEvilChat()  // ⇧⌘E stays a saved Evil chat
        #expect(state.route == .newChat)
        state.discardIncognito()
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [URL] = []
    func append(_ u: URL) { lock.withLock { value.append(u) } }
    var urls: [URL] { lock.withLock { value } }
}
