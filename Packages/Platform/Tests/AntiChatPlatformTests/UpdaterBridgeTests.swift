// M10.T03 AT-219 (unit leg): Info.plist Sparkle keys, feed resolution (production vs dev keys, override only with
// dev keys), NetworkGate refusal under Offline only (and the network_activity row), "Restart to update" storing
// and running Sparkle's install block, the gentle-reminder path that turns a scheduled update into the pill.
// The Sparkle updater itself is never started here (no network from tests).
//   make test-unit FILTER=UpdaterBridgeTests
import AntiChatFoundation
import AntiChatNetwork
import Foundation
import Sparkle
import Testing
@testable import AntiChatPlatform

@MainActor
@Suite(.serialized)
struct UpdaterBridgeTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized

    static func item(_ version: String = "1.2.0") -> SUAppcastItem {
        // Deprecated dictionary initializer: the designated one is private; enough for version + description.
        SUAppcastItem(dictionary: ["title": "AntiChat \(version)", "sparkle:version": "42",
                                   "sparkle:shortVersionString": version, "description": "<ul><li>Faster</li></ul>",
                                   "enclosure": ["url": "https://example.invalid/a.dmg", "length": "1",
                                                 "sparkle:edSignature": "x"]])!
    }

    static func policy(offline: Bool) -> NetworkPolicyStore {
        let d = UserDefaults.inMemory()
        let p = NetworkPolicyStore(defaults: d)
        p.offlineOnly = offline
        return p
    }

    @Test func infoPlistCarriesTheR219Keys() throws {
        let url = Self.repo.appendingPathComponent("App/AntiChat/Info.plist")
        let d = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        #expect(d["SUScheduledCheckInterval"] as? Int == 86400)
        #expect(d["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(d["SUAutomaticallyUpdate"] as? Bool == true)
        #expect(d["SUEnableSystemProfiling"] as? Bool == false)
        #expect(d["SURequireSignedFeed"] as? Bool == true)
        #expect(d["SUEnableInstallerLauncherService"] as? Bool == false)
        #expect(d["SUFeedURL"] == nil)  // the feed comes from Endpoints.plist via the delegate
        #expect(d["LSMinimumSystemVersion"] as? String == "26.0")
    }

    @Test func endpointsFeedsAreHTTPS() throws {
        let url = Self.repo.appendingPathComponent("Config/Endpoints.plist")
        let d = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        for k in ["AppcastURL", "AppcastDevURL"] {
            #expect((d[k] as? String)?.hasPrefix("https://") == true, "\(k)")
        }
    }

    @Test func feedResolution() {
        let ep: [String: Any] = ["AppcastURL": "https://s/appcast.xml", "AppcastDevURL": "https://s/appcast-dev.xml"]
        let prod = UpdateFeed.resolve(publicKey: "PRODKEY=", endpoints: ep, override: "http://192.168.64.1:8765/appcast-dev.xml")
        #expect(prod == UpdateFeed(url: "https://s/appcast.xml", devKeys: false))  // override ignored without dev keys
        let dev = UpdateFeed.resolve(publicKey: UpdateFeed.testPublicKey, endpoints: ep, override: nil)
        #expect(dev == UpdateFeed(url: "https://s/appcast-dev.xml", devKeys: true))
        let over = UpdateFeed.resolve(publicKey: UpdateFeed.testPublicKey, endpoints: ep, override: "http://h:1/f.xml")
        #expect(over.url == "http://h:1/f.xml")
    }

    /// RC review P2-8: a build where the dev feed is not allowed (Developer ID: neither DEBUG nor the dev-feed compile condition)
    /// gets no feed for the test key or a missing key, ignores the override, and never starts Sparkle; a production
    /// key is unaffected. This test process is DEBUG, so the dev feed is allowed here.
    @Test func releaseBuildRefusesTheTestKeyAndTheOverride() {
        let ep: [String: Any] = ["AppcastURL": "https://s/appcast.xml", "AppcastDevURL": "https://s/appcast-dev.xml"]
        #expect(UpdateFeed.devFeedAllowed)
        for key in [UpdateFeed.testPublicKey, nil] {
            let f = UpdateFeed.resolve(publicKey: key, endpoints: ep, override: "http://h:1/f.xml", devFeedAllowed: false)
            #expect(f.isDisabled && f.devKeys, "\(String(describing: key))")
            #expect(UpdateFeed.resolve(publicKey: key, endpoints: ep, override: nil, devFeedAllowed: false).isDisabled)
        }
        let prod = UpdateFeed.resolve(publicKey: "PRODKEY=", endpoints: ep, override: "http://h:1/f.xml", devFeedAllowed: false)
        #expect(prod == UpdateFeed(url: "https://s/appcast.xml", devKeys: false))
        let service = UpdaterService(state: UpdateState(), policy: Self.policy(offline: true), feed: UpdateFeed(url: "", devKeys: true))
        service.start()
        #expect(!service.isStarted, "no feed → Sparkle is never created")
    }

    @Test func testKeyConstantMatchesTheCommittedPub() throws {
        let pub = try String(contentsOf: Self.repo.appendingPathComponent("catalog/test-keys/sparkle-test.pub"), encoding: .utf8)
        #expect(pub.split(separator: "\n").first.map(String.init) == UpdateFeed.testPublicKey)
    }

    @Test func offlineOnlyRefusesTheCheckAndLogsIt() throws {
        final class Box: @unchecked Sendable { let lock = NSLock(); var events: [NetworkEvent] = [] }
        let box = Box()
        let saved = NetworkGate.activitySink
        NetworkGate.activitySink = { e in box.lock.withLock { box.events.append(e) } }
        defer { NetworkGate.activitySink = saved }
        let bridge = UpdaterBridge(state: UpdateState(), policy: Self.policy(offline: true),
                                   feed: UpdateFeed(url: "https://offline-check.invalid/appcast.xml", devKeys: false))
        let host = Bundle.main
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host,
                                 userDriver: SPUStandardUserDriver(hostBundle: host, delegate: nil), delegate: nil)
        #expect(throws: (any Error).self) { try bridge.updater(updater, mayPerform: .updatesInBackground) }
        // The sink is process-wide and other suites run in parallel: look only at this feed's host.
        let mine = box.lock.withLock { box.events }.filter { $0.host == "offline-check.invalid" }
        #expect(mine.map(\.outcome) == [.blocked])
        #expect(mine.first?.category == .updates)
    }

    @Test func restartRunsTheStoredInstallBlockOnce() async {
        let state = UpdateState()
        let bridge = UpdaterBridge(state: state, policy: Self.policy(offline: false),
                                   feed: UpdateFeed(url: "https://s/appcast.xml", devKeys: false))
        let host = Bundle.main
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host,
                                 userDriver: SPUStandardUserDriver(hostBundle: host, delegate: nil), delegate: nil)
        var ran = 0
        #expect(bridge.updater(updater, willInstallUpdateOnQuit: Self.item(), immediateInstallationBlock: { ran += 1 }))
        for _ in 0 ..< 50 where !state.showsPill { await Task.yield() }
        #expect(state.readyVersion == "1.2.0")
        #expect(bridge.hasInstallBlock)
        bridge.installNow()
        bridge.installNow()
        #expect(ran == 1)
    }

    @Test func gentleReminderBecomesThePillWhileActive() async {
        let state = UpdateState()
        let bridge = UpdaterBridge(state: state, policy: Self.policy(offline: false),
                                   feed: UpdateFeed(url: "https://s/appcast.xml", devKeys: false))
        #expect(bridge.supportsGentleScheduledUpdateReminders)
        #expect(!bridge.standardUserDriverShouldHandleShowingScheduledUpdate(Self.item(), andInImmediateFocus: true))
        // SPUUserUpdateState has no public initializer; the delegate method forwards to this when Sparkle won't show it.
        bridge.showGentleReminder(Self.item("1.3.0"))
        for _ in 0 ..< 50 where !state.showsPill { await Task.yield() }
        #expect(state.pillVersion == "1.3.0")
    }

    /// fix/review P1: with automatic downloads off, a gentle reminder comes without Sparkle's install block (nothing
    /// is downloaded). The pill must not be a "Restart to update" that does nothing: it is [Download and install],
    /// which hands the update to Sparkle's window (a user-initiated check: download, then install and relaunch).
    @Test func gentleReminderWithoutADownloadOffersDownloadThenInstall() async {
        let state = UpdateState()
        let bridge = UpdaterBridge(state: state, policy: Self.policy(offline: false),
                                   feed: UpdateFeed(url: "https://s/appcast.xml", devKeys: false))
        bridge.showGentleReminder(Self.item("1.3.0"))
        for _ in 0 ..< 50 where !state.showsPill { await Task.yield() }
        #expect(state.phase == .available(version: "1.3.0", notesHTML: "<ul><li>Faster</li></ul>"))
        #expect(state.needsDownload)
        #expect(state.readyVersion == nil, "not downloaded: no restart is offered")
        #expect(!bridge.hasInstallBlock)
        var downloads = 0
        bridge.installOrDownload { downloads += 1 }
        #expect(downloads == 1, "the pill's action starts the download-then-install flow")

        // Once Sparkle has downloaded it (its install block arrives), the pill becomes "Restart to update" and the
        // same action installs instead of downloading again.
        let host = Bundle.main
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host,
                                 userDriver: SPUStandardUserDriver(hostBundle: host, delegate: nil), delegate: nil)
        var installs = 0
        #expect(bridge.updater(updater, willInstallUpdateOnQuit: Self.item("1.3.0"), immediateInstallationBlock: { installs += 1 }))
        for _ in 0 ..< 50 where state.needsDownload { await Task.yield() }
        #expect(state.readyVersion == "1.3.0")
        #expect(!state.needsDownload)
        bridge.installOrDownload { downloads += 1 }
        #expect(installs == 1)
        #expect(downloads == 1)
    }

    /// fix/review P1: a reminder that arrives after the download (install block stored) stays "Restart to update".
    @Test func gentleReminderAfterTheDownloadKeepsRestart() async {
        let state = UpdateState()
        let bridge = UpdaterBridge(state: state, policy: Self.policy(offline: false),
                                   feed: UpdateFeed(url: "https://s/appcast.xml", devKeys: false))
        let host = Bundle.main
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host,
                                 userDriver: SPUStandardUserDriver(hostBundle: host, delegate: nil), delegate: nil)
        _ = bridge.updater(updater, willInstallUpdateOnQuit: Self.item("1.4.0"), immediateInstallationBlock: {})
        for _ in 0 ..< 50 where !state.showsPill { await Task.yield() }
        bridge.showGentleReminder(Self.item("1.4.0"))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(state.readyVersion == "1.4.0")
        #expect(!state.needsDownload)
    }

    /// fix/review P1: no pill, no action (a stray click after the state was cleared does not start a check).
    @Test func noPillNoDownload() {
        let bridge = UpdaterBridge(state: UpdateState(), policy: Self.policy(offline: false),
                                   feed: UpdateFeed(url: "https://s/appcast.xml", devKeys: false))
        var downloads = 0
        bridge.installOrDownload { downloads += 1 }
        #expect(downloads == 0)
    }

    @Test func betaChannelOnlyWhenEnabled() {
        let saved = UpdateFeed.defaults
        UpdateFeed.defaults = UserDefaults.inMemory()
        defer { UpdateFeed.defaults = saved }
        let bridge = UpdaterBridge(state: UpdateState(), policy: Self.policy(offline: false),
                                   feed: UpdateFeed(url: "https://s/a.xml", devKeys: false))
        let host = Bundle.main
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host,
                                 userDriver: SPUStandardUserDriver(hostBundle: host, delegate: nil), delegate: nil)
        #expect(bridge.allowedChannels(for: updater).isEmpty)
        UpdateFeed.betaEnabled = true
        #expect(bridge.allowedChannels(for: updater) == ["beta"])
    }
}
