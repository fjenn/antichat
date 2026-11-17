// M2.T17 (R-210, R-211; P-platform-06): Evil Mode state and actions, app side.
//   on        = FeatureFlag.evilMode && enabled (Settings / onboarding) && the current terms version consented
//   showsSwitch = on && !hidden            (ModeSwitch, ⇧⌘E, Settings › Evil rows; Hide deletes nothing, AC6)
//   readOnly(chat) = an Evil chat while Evil is off (composer disabled, `evil.readOnly`)
//   continueInNewChat(from:mode:)  copies the chat's active path into a new chat of the other mode (AC2)
//   deleteAllEvilChats()           one action (Settings › Evil Mode, `set.evil.deleteChats`)
//   mayOpen(mode:)                 Touch ID / password when `set.evil.touchid` is on (AC4; LAContext in AntiChatUI)
// Product rule (D-005, D-006): Evil = abliterated models + the catalog tone sentence. No filter, safety prompt or
// keyword list exists in either mode; the only filter in the product is ChildSafetyCheck.
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB

/// Touch ID / password before an Evil chat opens (LocalAuthentication in AntiChatUI; `-FakeLAContext` in Debug).
public protocol EvilAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

public final class EvilModeManager: @unchecked Sendable {
    public enum Key {
        public static let enabled = "evil.enabled"
        public static let hidden = "evil.hidden"
        public static let touchID = "evil.touchID"
        public static let memory = "evil.memory"
        public static let lastMode = "evil.lastMode"
    }

    public let database: AppDatabase
    public let consent: ConsentStore
    public let termsVersion: String
    let defaults: UserDefaults
    let auth: (any EvilAuthenticating)?
    let flagDefaults: UserDefaults

    public init(database: AppDatabase, termsVersion: String, defaults: UserDefaults = AppDefaults.standard,
                auth: (any EvilAuthenticating)? = nil, flagDefaults: UserDefaults = AppDefaults.standard) {
        self.database = database
        consent = ConsentStore(database)
        self.termsVersion = termsVersion
        self.defaults = defaults
        self.auth = auth
        self.flagDefaults = flagDefaults
    }

    // MARK: State

    public var isConsented: Bool { consent.hasAccepted(version: termsVersion) }
    /// Off on a fresh container (EvilDefaultsTests).
    public var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }
    public var isHidden: Bool { defaults.bool(forKey: Key.hidden) }
    public var requiresTouchID: Bool { defaults.bool(forKey: Key.touchID) }
    public var usesMemory: Bool { defaults.bool(forKey: Key.memory) }
    public var isOn: Bool { FeatureFlag.evilMode.isEnabled(flagDefaults) && isEnabled && isConsented }
    public var showsSwitch: Bool { isOn && !isHidden }
    /// The enable sheet must be shown (again) before Evil can be turned on: no consent for this terms version.
    public var needsConsent: Bool { !isConsented }

    // MARK: Enable / disable / hide (R-211 AC1–AC3, R-210 AC6)

    /// The enable sheet's Continue: records the consent (adult self-declaration) and turns Evil on.
    public func enable(adultSelfDeclared: Bool, at date: Date = Date()) throws {
        try consent.accept(version: termsVersion, adultSelfDeclared: adultSelfDeclared, at: date)
        defaults.set(true, forKey: Key.enabled)
    }

    /// Turn off: the switch goes; existing Evil chats stay, read-only until Evil is on again.
    public func disable() { defaults.set(false, forKey: Key.enabled) }

    /// Hide: removes the ModeSwitch and ⇧⌘E for shared Macs; deletes nothing.
    public func setHidden(_ on: Bool) { defaults.set(on, forKey: Key.hidden) }
    public func setTouchID(_ on: Bool) { defaults.set(on, forKey: Key.touchID) }
    public func setMemory(_ on: Bool) { defaults.set(on, forKey: Key.memory) }

    // MARK: Per-chat mode (R-210 AC1, AC2)

    /// A new chat's mode: Normal (owner 2026-11-17; it was the last used mode). Evil is chosen per chat.
    public var defaultModeForNewChat: ChatMode { .normal }

    /// The last mode the switch was used in (Normal when never), whatever Evil's state now.
    public var lastMode: ChatMode { defaults.string(forKey: Key.lastMode).flatMap(ChatMode.init(rawValue:)) ?? .normal }

    public func recordLastMode(_ m: ChatMode) { defaults.set(m.rawValue, forKey: Key.lastMode) }

    /// An Evil chat while Evil is off: shown, but its composer is disabled (`evil.readOnly`).
    public func isReadOnly(_ mode: ChatMode) -> Bool { mode == .evil && !isOn }

    /// Copies the active path of `chatID` into a new chat of `mode` (the lock popover's two buttons). Returns the
    /// new chat's id. A chat with no message yet just gets a new empty chat of `mode`.
    @discardableResult
    public func continueInNewChat(from chatID: String, mode: ChatMode, title: String? = nil) throws -> String {
        recordLastMode(mode)
        return try database.write { db in
            guard let source = try ChatRecord.fetchOne(db, key: chatID) else { throw StorageError.notFound("chat \(chatID)") }
            guard let leaf = try MessageTree.visiblePath(chatID, db: db).last else {
                let c = ChatRecord(title: "", mode: mode)
                try c.insert(db)
                return c.id
            }
            return try MessageTree.branchCopy(upTo: leaf.id, title: title ?? source.title, mode: mode, db: db)
        }
    }

    /// "Delete all Evil chats" (one action, after a confirm). Returns how many went.
    @discardableResult
    public func deleteAllEvilChats() throws -> Int {
        let ids = try database.write { db -> [String] in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM chat WHERE mode = ?", arguments: [ChatMode.evil.rawValue])
            try ChatRecord.filter(Column("mode") == ChatMode.evil.rawValue).deleteAll(db)
            return ids
        }
        SheetSessions.shared.close(chatIDs: ids)  // M6 review #5
        FileToolsClient.release(chatIDs: ids)  // M6.T21 review #6: interpreter + jail
        return ids.count
    }

    public func evilChatCount() -> Int {
        (try? database.read { db in try ChatRecord.filter(Column("mode") == ChatMode.evil.rawValue).fetchCount(db) }) ?? 0
    }

    // MARK: Touch ID (R-211 AC4)

    /// Normal chats always open; Evil chats need LocalAuthentication when the setting is on.
    public func mayOpen(mode: ChatMode, reason: String) async -> Bool {
        guard mode == .evil, requiresTouchID else { return true }
        guard let auth else { return false }
        return await auth.authenticate(reason: reason)
    }
}
