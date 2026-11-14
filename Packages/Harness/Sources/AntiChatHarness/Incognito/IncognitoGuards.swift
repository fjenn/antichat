// IncognitoGuards (M1.T20 step 4, R-090, NFR-PR3, P-shell-14 + RL-005). Every place an incognito chat could reach
// the disk, and the guard that stops it. Each guard has a unit test (IncognitoGuardsTests unless noted).
//
//  1. Store        All records of the chat (chat, message, parts, attachments, provenance, feedback, tool
//                  permissions, compaction summaries) go to the session's in-memory `DatabaseQueue` through
//                  `StoreRouter`; `PRAGMA temp_store=MEMORY` (no spill files).            `store(_:)`, IncognitoStoreTests
//  2. Files        Paste-card blobs stay in process memory (`PastedTextAttachmentStore` `memory:` paths); xfer files
//                  (M4+) go to `NSTemporaryDirectory()/AntiChat-incognito-<uuid>/` (0700), deleted on close and at
//                  launch (`IncognitoSession.sweepStaleTempDirectories`).                  `fileLocation(_:session:)`
//  3. Drafts       No `draft` row for an incognito chat (M1.T21 asks `StoreRouter.persistsDrafts`). `allowsDraft`
//  4. Titles       No title model call; the toolbar shows `title.incognito`.            `allowsTitle`
//  5. KV slots     Every request carries `incognito: true` (`IncognitoEngine`); the llama-server adapter never saves
//                  or restores that session's slot (`LlamaSlotTable`, LlamaSlotTableTests) and never runs with
//                  `--log-file`; MLX keeps its prefix cache in memory only.              `flag(_:)`, `allowsSlotSave`
//  6. Network      `NetworkGate.incognitoConfiguration()` (ephemeral, `URLCache` disk 0); no `network_activity`
//                  rows (`NetworkGate.recordsActivity(incognito:)`).                     `allowsNetworkActivityRecord`
//  7. Logs         `AppLog` category-level redaction while an incognito session is open (app) or an incognito
//                  request runs (helper, `AppLog.$incognito`): content categories go `.private` to the unified log
//                  and never to the file log; `AppLog.content` lines are dropped.        `logRedactionActive`
//  8. Diagnostics  Crash / problem-report payloads drop every field of an incognito chat.  `diagnostics(_:excluding:)`
//  9. Media jobs   A job that would persist output to disk is refused for an incognito chat (M4 calls it).
//                                                                                          `checkMediaJob(persistsOutput:incognito:)`
// 10. Window       `NSWindow.isRestorable = false` while the window shows an incognito chat (no Saved Application
//                  State); the UI applies it.                                             `windowIsRestorable(showingIncognito:)`
// 11. Memory       Personalized reads custom instructions and memory, read-only; Unpersonalized omits them; nothing
//                  is ever written (`PromptSettings(derivedFrom:)` ignores `update`).    `IncognitoPersonalization`
// 12. Unread       No unread flag write for an incognito chat (it is never in the sidebar). `allowsUnreadFlag`
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation

public enum IncognitoGuards {
    public enum Refusal: Error, Equatable, Sendable {
        case persistentStore
        case diskOutput
    }

    /// Guard 1: the store an incognito chat may use (in memory only).
    public static func store(_ database: AppDatabase) throws -> AppDatabase {
        guard database.isInMemory else { throw Refusal.persistentStore }
        return database
    }

    /// Guard 2: where an incognito file may live: inside the session's temp directory, else refused.
    public static func fileLocation(_ url: URL, session: IncognitoSession) throws -> URL {
        let dir = session.tempDirectory.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(dir) else { throw Refusal.diskOutput }
        return url
    }

    /// Guard 3.
    public static func allowsDraft(chatID: String?, router: StoreRouter) -> Bool { router.persistsDrafts(for: chatID) }

    /// Guard 4.
    public static func allowsTitle(_ environment: ChatEnvironment) -> Bool { !environment.isIncognito }

    /// Guard 5: the request as an incognito chat sends it.
    public static func flag(_ request: ChatRequest) -> ChatRequest {
        var r = request
        r.incognito = true
        return r
    }

    /// Guard 5: whether the engine may save this request's KV slot to disk.
    public static func allowsSlotSave(_ request: ChatRequest) -> Bool { !request.incognito }

    /// Guard 6.
    public static func allowsNetworkActivityRecord(incognito: Bool) -> Bool { !incognito }

    /// Guard 7.
    public static var logRedactionActive: Bool { AppLog.isRedacting }

    /// Guard 8: a diagnostics payload (`key → value`, keys may name chat ids) without any incognito chat's fields.
    public static func diagnostics(_ payload: [String: String], excluding router: StoreRouter) -> [String: String] {
        let hidden = router.ephemeralChatIDs
        guard !hidden.isEmpty else { return payload }
        return payload.filter { key, value in !hidden.contains { key.contains($0) || value.contains($0) } }
    }

    /// Guard 9: media jobs (M4) call this before they start.
    public static func checkMediaJob(persistsOutput: Bool, incognito: Bool) throws {
        if incognito, persistsOutput { throw Refusal.diskOutput }
    }

    /// Guard 10.
    public static func windowIsRestorable(showingIncognito: Bool) -> Bool { !showingIncognito }

    /// Guard 12.
    public static func allowsUnreadFlag(chatID: String, router: StoreRouter) -> Bool { !router.isEphemeral(chatID) }
}
