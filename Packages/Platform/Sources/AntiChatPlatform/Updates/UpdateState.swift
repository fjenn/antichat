// M10.T03 (R-219 AC2/AC3): what the app knows about a Sparkle update, for the sidebar pill ("Restart to update",
// `pill.update`), the release-notes sheet and Settings › Updates (`update.failed`). Main-actor, @Observable.
// `UpdateFeed` resolves the appcast URL: Endpoints.plist `AppcastURL` (production key) or `AppcastDevURL`
// (builds whose SUPublicEDKey is the committed test key, i.e. dev-keys builds), with the Debug / adhoc-dev-only
// `AntiChatFeedURLOverride` default for the VM/local upgrade tests (never `SUFeedURL` in defaults).
import AntiChatFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class UpdateState {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        /// Downloaded and ready: Sparkle installs on quit or on [Restart to update].
        case ready(version: String, notesHTML: String?)
        /// fix/review P1: found by a scheduled check but not downloaded (automatic downloads off, a gentle reminder).
        /// The pill offers [Download and install] (Sparkle's own window downloads, then installs and relaunches),
        /// never "Restart to update": there is nothing to restart into yet.
        case available(version: String, notesHTML: String?)
        case failed(String)
    }

    public var phase: Phase = .idle
    public var automaticallyChecks = true
    public var automaticallyDownloads = true
    public var beta = UpdateFeed.betaEnabled
    /// The pill shows while an update waits for a restart, or (automatic downloads off) for its download.
    public var showsPill: Bool { pillVersion != nil }
    /// Downloaded: [Restart to update] installs it now.
    public var readyVersion: String? { if case .ready(let v, _) = phase { v } else { nil } }
    /// Found but not downloaded: the pill offers [Download and install], not a restart.
    public var needsDownload: Bool { if case .available = phase { true } else { false } }
    /// The pill's update (ready or available).
    public var pillVersion: String? {
        switch phase {
        case .ready(let v, _), .available(let v, _): v
        default: nil
        }
    }
    public var pillNotesHTML: String? {
        switch phase {
        case .ready(_, let n), .available(_, let n): n
        default: nil
        }
    }

    public init() {}
}

public struct UpdateFeed: Equatable, Sendable {
    public static let betaKey = "updates.beta"

    public var url: String
    public var devKeys: Bool

    public init(url: String, devKeys: Bool) {
        self.url = url
        self.devKeys = devKeys
    }

    nonisolated(unsafe) static var defaults: UserDefaults = AppDefaults.standard

    public static var betaEnabled: Bool {
        get { defaults.bool(forKey: betaKey) }
        set { defaults.set(newValue, forKey: betaKey) }
    }

    /// The committed Sparkle TEST public key (catalog/test-keys/sparkle-test.pub, M0.T12). A build that carries it
    /// is a dev-keys build: it reads the dev feed and honours the override.
    public static let testPublicKey = "Lfhwtsep1tKBCxpS4LkzzJhO7uuNCWyI7p/eS8X8hlQ="

    /// RC review P2-8: whether this build may use the committed Sparkle test key and the feed override at all. Only
    /// Debug builds and adhoc/dev-signed dev-keys builds (build-release.sh compiles those with ANTICHAT_DEV_FEED;
    /// the VM upgrade test AT-FA-12 uses one). A Developer ID build never: there a test key (or no key) means no
    /// feed, so Sparkle never starts, and the override key is not even compiled in. tools/ci/devfeed-guard.py
    /// (make audit, preflight) keeps it so.
    public static var devFeedAllowed: Bool {
        #if DEBUG || ANTICHAT_DEV_FEED
        true
        #else
        false
        #endif
    }

    /// The `AntiChatFeedURLOverride` default, read only where the dev feed is allowed.
    static func feedOverride(_ defaults: UserDefaults) -> String? {
        #if DEBUG || ANTICHAT_DEV_FEED
        defaults.string(forKey: "AntiChatFeedURLOverride")
        #else
        nil
        #endif
    }

    /// No feed: Sparkle is not started (`UpdaterService.start`).
    public var isDisabled: Bool { url.isEmpty }

    public static func current(bundle: Bundle = .main, defaults: UserDefaults = AppDefaults.standard) -> UpdateFeed {
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let endpoints = bundle.url(forResource: "Endpoints", withExtension: "plist").flatMap { NSDictionary(contentsOf: $0) }
        return resolve(publicKey: key, endpoints: endpoints as? [String: Any] ?? [:], override: feedOverride(defaults))
    }

    /// Pure resolution (unit-tested): production key → `AppcastURL`; test key → `AppcastDevURL`, or the override
    /// when one is set (dev keys only — a production build ignores it). Where the dev feed is not allowed
    /// (`devFeedAllowed`), a test key or a missing key gives no feed at all and the override is ignored.
    public static func resolve(publicKey: String?, endpoints: [String: Any], override: String?,
                               devFeedAllowed: Bool = UpdateFeed.devFeedAllowed) -> UpdateFeed {
        let dev = publicKey == nil || publicKey == testPublicKey
        if dev, !devFeedAllowed { return UpdateFeed(url: "", devKeys: true) }
        if dev, let o = override, !o.isEmpty { return UpdateFeed(url: o, devKeys: true) }
        let key = dev ? "AppcastDevURL" : "AppcastURL"
        return UpdateFeed(url: endpoints[key] as? String ?? "", devKeys: dev)
    }
}
