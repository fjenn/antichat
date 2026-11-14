// M10.T09 AT-FA-10 (R-208 AC2): the last-shown chat per window in the app's own store, and the launch decision that
// reopens it after a kill or crash independent of macOS window restoration (LastShownChats.swift).
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct LastShownChatsTests {
    typealias W = LastShownSnapshot.Window

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("last-shown-\(UUID().uuidString)/\(LastShownChatStore.fileName)")
    }

    private func read(_ url: URL) throws -> LastShownSnapshot {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(LastShownSnapshot.self, from: Data(contentsOf: url))
    }

    /// A store whose clock steps one second per call.
    private func store(_ url: URL, debounce: Duration = .milliseconds(50)) -> LastShownChatStore {
        var t = Date(timeIntervalSince1970: 1_000)
        return LastShownChatStore(url: url, debounce: debounce) { t += 1; return t }
    }

    // MARK: Launch decision (pure)

    @Test func pendingOnlyAfterAnUncleanExitAndWhenAllowed() {
        let ws = [W(key: "a", chatID: "c1", active: Date(timeIntervalSince1970: 10)),
                  W(key: "b", chatID: "c2", active: Date(timeIntervalSince1970: 20))]
        #expect(LaunchReopen.pending(previous: nil, reopenAllowed: true).isEmpty)  // first launch
        #expect(LaunchReopen.pending(previous: .init(running: false, windows: ws), reopenAllowed: true).isEmpty)  // quit
        #expect(LaunchReopen.pending(previous: .init(running: true, windows: ws), reopenAllowed: false).isEmpty)
        // Killed: newest first.
        #expect(LaunchReopen.pending(previous: .init(running: true, windows: ws), reopenAllowed: true).map(\.key) == ["b", "a"])
    }

    @Test func notRestoredWindowTakesTheNewestEntryOnce() {
        var pending = [W(key: "b", chatID: "c2", active: .distantFuture), W(key: "a", chatID: "c1", active: .distantPast)]
        var fresh = false
        #expect(LaunchReopen.claim(key: nil, restored: nil, pending: &pending, freshClaimed: &fresh) { _ in true } == .open("c2"))
        #expect(fresh && pending.map(\.key) == ["a"])
        // A second non-restored window (⌥⌘N right after launch) is a new chat.
        #expect(LaunchReopen.claim(key: nil, restored: nil, pending: &pending, freshClaimed: &fresh) { _ in true } == .keep)
        #expect(pending.map(\.key) == ["a"])
    }

    @Test func restoredWindowTakesItsOwnNewerEntry() {
        var pending = [W(key: "b", chatID: "c2", active: .distantFuture), W(key: "a", chatID: "c9", active: .distantPast)]
        var fresh = false
        // macOS restored window "a" with a stale chat: the store's entry is newer.
        #expect(LaunchReopen.claim(key: "a", restored: .chat("c1"), pending: &pending, freshClaimed: &fresh) { _ in true } == .open("c9"))
        #expect(!fresh && pending.map(\.key) == ["b"])
        // Restored with the same chat: nothing to change. Unknown key: keep the restored value.
        var p2 = [W(key: "a", chatID: "c1", active: .now)]
        #expect(LaunchReopen.claim(key: "a", restored: .chat("c1"), pending: &p2, freshClaimed: &fresh) { _ in true } == .keep)
        var p3 = [W(key: "z", chatID: "c1", active: .now)]
        #expect(LaunchReopen.claim(key: "a", restored: .chat("c7"), pending: &p3, freshClaimed: &fresh) { _ in true } == .keep)
        #expect(p3.count == 1)
    }

    @Test func neverReopensIncognitoNorAMissingChatNorWithoutPending() {
        var fresh = false
        var pending = [W(key: "a", chatID: "c1", active: .now)]
        #expect(LaunchReopen.claim(key: nil, restored: .incognito, pending: &pending, freshClaimed: &fresh) { _ in true } == .keep)
        #expect(pending.count == 1 && !fresh)
        // The chat was deleted (or a backup was restored): a new chat.
        #expect(LaunchReopen.claim(key: nil, restored: nil, pending: &pending, freshClaimed: &fresh) { _ in false } == .keep)
        // The newest window showed no saved chat (a new chat): it stays a new chat.
        var none = [W(key: "a", chatID: nil, active: .distantFuture), W(key: "b", chatID: "c1", active: .distantPast)]
        fresh = false
        #expect(LaunchReopen.claim(key: nil, restored: nil, pending: &none, freshClaimed: &fresh) { _ in true } == .keep)
        var empty: [W] = []
        #expect(LaunchReopen.claim(key: nil, restored: nil, pending: &empty, freshClaimed: &fresh) { _ in true } == .keep)
    }

    @Test func userReopenWindowsChoice() throws {
        let d = UserDefaults.inMemory()
        #expect(LaunchReopen.userKeepsWindows(d) == (UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool ?? true))
        d.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        #expect(!LaunchReopen.userKeepsWindows(d))
        d.set(true, forKey: "NSQuitAlwaysKeepsWindows")
        #expect(LaunchReopen.userKeepsWindows(d))
    }

    @Test func wantedOnlyInTheAppWithSavedStateOnDisk() throws {
        let d = UserDefaults.inMemory()
        let app = URL(fileURLWithPath: "/Applications/AntiChat.app")
        #expect(LastShownChatStore.wanted(defaults: d, environment: [:], bundleURL: app, inMemoryDatabase: false))
        #expect(!LastShownChatStore.wanted(defaults: d, environment: [:], bundleURL: app, inMemoryDatabase: true))
        #expect(!LastShownChatStore.wanted(defaults: d, environment: [:], bundleURL: URL(fileURLWithPath: "/usr/bin/xctest"),
                                           inMemoryDatabase: false))
        #expect(!LastShownChatStore.wanted(defaults: d, environment: ["XCTestConfigurationFilePath": "/x"], bundleURL: app,
                                           inMemoryDatabase: false))
        d.set("YES", forKey: "ApplePersistenceIgnoreState")  // -ApplePersistenceIgnoreState YES (UI tests, probes)
        #expect(!LastShownChatStore.wanted(defaults: d, environment: [:], bundleURL: app, inMemoryDatabase: false))
    }

    // MARK: Persistence

    @Test func switchIsWrittenAtOnceAndIncognitoNever() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store(url)
        s.shown(key: "a", chatID: "c1", incognito: false)
        #expect(s.writes == 0 && !FileManager.default.fileExists(atPath: url.path))  // off until start()
        s.start(reopenAllowed: true)
        #expect(try read(url) == LastShownSnapshot(running: true, windows: []))
        s.shown(key: "a", chatID: "c1", incognito: false)
        #expect(try read(url).windows.map(\.chatID) == ["c1"])  // flushed on the switch, no debounce
        let n = s.writes
        s.shown(key: "a", chatID: "c1", incognito: false)  // same chat: no write
        #expect(s.writes == n)
        // The window goes incognito: nothing is written; its entry stays on the last saved chat.
        let before = try Data(contentsOf: url)
        s.shown(key: "a", chatID: nil, incognito: true)
        s.activated(key: "a", incognito: true)
        let after = try Data(contentsOf: url)
        #expect(s.writes == n && after == before)
        #expect(!String(decoding: before, as: UTF8.self).contains("incognito"))
        s.shown(key: "a", chatID: nil, incognito: false)  // back on a new chat
        #expect(try read(url).windows.map(\.chatID) == [nil])
        s.shown(key: "b", chatID: "c2", incognito: false)
        s.closed(key: "a")  // a closed window is not reopened
        #expect(try read(url).windows.map(\.key) == ["b"])
    }

    @Test func becomingKeyIsDebounced() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store(url, debounce: .milliseconds(100))
        s.start(reopenAllowed: true)
        s.shown(key: "a", chatID: "c1", incognito: false)
        s.shown(key: "b", chatID: "c2", incognito: false)
        let n = s.writes
        let bActive = try read(url).windows.first { $0.key == "b" }!.active
        for _ in 0..<5 { s.activated(key: "a", incognito: false) }
        #expect(s.writes == n)  // not yet
        // One write for the burst (polled: the parallel suite can hold the main actor for a while).
        let deadline = ContinuousClock.now + .seconds(20)
        while s.writes == n, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(s.writes == n + 1)
        let a = try read(url).windows.first { $0.key == "a" }!
        #expect(a.active > bActive)
        // A switch flushes at once and cancels a pending reorder write.
        s.activated(key: "b", incognito: false)
        s.shown(key: "a", chatID: "c3", incognito: false)
        #expect(s.writes == n + 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(s.writes == n + 2)
    }

    @Test func killedRunReopensAndQuitRunDoesNot() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Run 1: two windows, then kill -9 (no cleanExit).
        let r1 = store(url)
        r1.start(reopenAllowed: true)
        r1.shown(key: "a", chatID: "old", incognito: false)
        r1.shown(key: "b", chatID: "killed", incognito: false)
        // Run 2: macOS restored nothing; the launch window takes the newest chat, the other opens its own window.
        let r2 = store(url)
        r2.start(reopenAllowed: true)
        #expect(r2.pending.map(\.chatID) == ["killed", "old"])
        #expect(try read(url).running)
        #expect(try read(url).windows.count == 2)  // kept until the windows claimed them
        #expect(r2.claim(key: nil, restored: nil) { _ in true } == .open("killed"))
        r2.shown(key: "n1", chatID: "killed", incognito: false)
        var opened: [String] = []
        r2.settleLaunch { opened = $0 }
        #expect(opened == ["old"] && r2.pending.isEmpty)
        #expect(r2.reopened == ["killed", "old"] && r2.launchSummary == "previous run unclean, reopen 2 window(s)")
        #expect(try read(url).windows.map(\.key) == ["n1"])  // the previous run's entries are gone
        #expect(r2.claim(key: nil, restored: nil) { _ in true } == .keep)  // a later window is a new chat
        // Run 2 quits normally: run 3 leaves reopening to macOS.
        r2.cleanExit()
        #expect(try !read(url).running)
        let r3 = store(url)
        r3.start(reopenAllowed: true)
        #expect(r3.pending.isEmpty)
        #expect(try read(url) == LastShownSnapshot(running: true, windows: []))
        #expect(r3.claim(key: nil, restored: nil) { _ in true } == .keep)
    }

    @Test func reopenOffKeepsWritingButReopensNothing() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let r1 = store(url)
        r1.start(reopenAllowed: true)
        r1.shown(key: "a", chatID: "c1", incognito: false)
        let r2 = store(url)
        r2.start(reopenAllowed: false)  // "Close windows when quitting an application"
        #expect(r2.pending.isEmpty)
        #expect(r2.claim(key: nil, restored: nil) { _ in true } == .keep)
    }

    @Test func unreadableFileIsAFirstLaunch() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let s = store(url)
        s.start(reopenAllowed: true)
        #expect(s.pending.isEmpty)
        #expect(try read(url) == LastShownSnapshot(running: true, windows: []))
    }
}
