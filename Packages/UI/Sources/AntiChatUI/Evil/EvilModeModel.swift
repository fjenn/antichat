// M2.T17 (R-210, R-211, R-240): the UI side of Evil Mode. Wraps Harness' EvilModeManager (consent, per-chat lock,
// hide, Touch ID, read-only) as an observable for the ModeSwitch, ⇧⌘E, the frame and Settings › Evil Mode; owns the
// two composition-root conformances: the catalog tone sentence (ToneSentenceProviding) and LocalAuthentication
// (EvilAuthenticating, `-FakeLAContext succeed|fail` in Debug). The consent screen is a self-declaration of
// adulthood and responsibility (D-005); no filter is added anywhere (D-006).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
public final class EvilModeModel {
    /// The app's instance (installed at the composition root; tests build their own).
    public private(set) static var shared: EvilModeModel?

    @ObservationIgnored public let manager: EvilModeManager
    public private(set) var isOn = false
    public private(set) var showsSwitch = false
    public private(set) var isHidden = false
    public private(set) var requiresTouchID = false
    public private(set) var usesMemory = false
    public private(set) var isEnabled = false
    public private(set) var needsConsent = true
    public private(set) var evilChatCount = 0
    /// Settings › Evil Mode → enable: the S-24 sheet.
    public var showEnableSheet = false
    /// Debug `-FakeEvilEnabled YES`: the switch shows without consent (composer fixtures, M1 tests).
    @ObservationIgnored let forceOn: Bool

    public init(manager: EvilModeManager, forceOn: Bool = false) {
        self.manager = manager
        self.forceOn = forceOn
        refresh()
    }

    @discardableResult
    public static func install(database: AppDatabase) -> EvilModeModel {
        if let shared { return shared }
        let m = EvilModeModel(manager: EvilModeManager(database: database, termsVersion: termsVersion(), defaults: .antichat,
                                                       auth: LAAuthenticator(), flagDefaults: .antichat),
                              forceOn: LaunchOptions.current.fakeEvilEnabled)
        shared = m
        return m
    }

    /// `EvilTerms.version` of the copy the sheet shows (`onb.3.body` + `onb.3.adult`).
    public static func termsVersion() -> String {
        EvilTerms.version(body: CopyKey("onb.3.body").string(), adult: CopyKey("onb.3.adult").string())
    }

    public func refresh() {
        isEnabled = manager.isEnabled
        isOn = manager.isOn || forceOn
        isHidden = manager.isHidden
        showsSwitch = isOn && !isHidden
        requiresTouchID = manager.requiresTouchID
        usesMemory = manager.usesMemory
        needsConsent = manager.needsConsent
        evilChatCount = manager.evilChatCount()
    }

    // MARK: Actions

    /// The sheet's Continue (enabled only with the adult box ticked).
    public func enable(adultSelfDeclared: Bool) throws {
        try manager.enable(adultSelfDeclared: adultSelfDeclared)
        showEnableSheet = false
        refresh()
    }

    /// The Settings toggle: on → the sheet when this terms version has no consent, else straight on.
    public func requestEnable() {
        if manager.needsConsent { showEnableSheet = true } else { try? manager.enable(adultSelfDeclared: true); refresh() }
    }

    public func disable() { manager.disable(); refresh() }
    public func setHidden(_ on: Bool) { manager.setHidden(on); refresh() }
    public func setTouchID(_ on: Bool) { manager.setTouchID(on); refresh() }
    public func setMemory(_ on: Bool) { manager.setMemory(on); refresh() }

    @discardableResult
    public func deleteAllEvilChats() -> Int {
        let n = (try? manager.deleteAllEvilChats()) ?? 0
        refresh()
        return n
    }

    public var defaultModeForNewChat: ComposerChatMode {
        guard showsSwitch else { return .normal }
        // The switch shows (consented, or the Debug `-FakeEvilEnabled` force): the last used mode. (Asking the manager's
        // `defaultModeForNewChat` gave Normal under the force — no consent row — so a new Evil chat fell back to Normal.)
        return manager.lastMode == .evil ? .evil : .normal
    }

    public func recordLastMode(_ m: ComposerChatMode) { manager.recordLastMode(m == .evil ? .evil : .normal) }
    public func isReadOnly(_ m: ComposerChatMode) -> Bool { m == .evil && !isOn }

    /// Touch ID / password before an Evil chat shows (R-211 AC4).
    public func mayOpen(_ m: ComposerChatMode) async -> Bool {
        await manager.mayOpen(mode: m == .evil ? .evil : .normal, reason: CopyKey("set.evil.touchid").string())
    }
}

/// LocalAuthentication `.deviceOwnerAuthentication` (Touch ID, falling back to the password; works on any Mac).
public struct LAAuthenticator: EvilAuthenticating {
    public init() {}
    public func authenticate(reason: String) async -> Bool {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let fake = LaunchOptions.current.fakeLAContext { return fake }
        #endif
        let ctx = LAContext()
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// The catalog `tone_sentence` (R-240 AC1): the current verified catalog's, else the bundled baseline's.
public struct CatalogToneSentence: ToneSentenceProviding {
    public init() {}
    public var toneSentence: String {
        if let s = CatalogLaunch.shared?.catalog?.toneSentence, !s.isEmpty { return s }
        return Self.baseline
    }

    /// The bundled baseline catalog's sentence (read once).
    static let baseline: String = {
        guard let b = CatalogStore.bundledBaseline(),
              let obj = try? JSONSerialization.jsonObject(with: b.data) as? [String: Any] else { return "" }
        return obj["tone_sentence"] as? String ?? ""
    }()
}

extension ComposerChatMode {
    public var chatMode: ChatMode { self == .evil ? .evil : .normal }
    public init(_ m: ChatMode) { self = m == .evil ? .evil : .normal }
}
