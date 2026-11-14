// Draft autosave binding (M1.T21, R-302; P-shell-15). One per window (ChatSessions): connects the window's composer
// (M1.T08 ComposerModel: text + paste-card / file tray) to the Storage `DraftStore`:
//   - every composer change → `DraftStore.update` (written 500 ms after the last change, ≤ 1 s, AT-302);
//   - the shown chat changes (sidebar, ⌘N, launch) → the left chat's pending draft is written at once, and the new
//     chat's draft is restored into the composer (none: the composer empties);
//   - a send → the chat's draft is cleared (pending at once, the row's delete enqueued on the writer);
//   - app termination (`NSApplication.willTerminateNotification`, posted from `applicationWillTerminate`, so no
//     AppDelegate is needed; M1.T24 owns it) → `flush()`: the pending debounce is written synchronously;
//   - incognito: `ComposerModel.isIncognito` (and DraftStore's `isIncognito` seam for M1.T20's StoreRouter) keeps the
//     draft in memory only — never in the `draft` table.
// Change attribution: a change is saved under the chat the binding shows (`shownKey`); a change reported for another
// chat is a switch (restore, no save), so text left over from the previous chat is never written to the next one, and a
// change equal to what was last restored or saved is not written again.
import AntiChatStorage
import AppKit
import Foundation

@MainActor
public final class DraftBinding {
    public let store: DraftStore
    private weak var composer: ComposerModel?
    /// The chat whose draft the composer shows (nil until the first `show`).
    public private(set) var shownKey: DraftStore.Key?
    /// What the composer held when it was last restored or saved for `shownKey`.
    private var lastSynced = DraftStore.Draft.empty
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    public init(store: DraftStore, composer: ComposerModel) {
        self.store = store
        self.composer = composer
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [store] _ in store.flush() }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    private var incognito: Bool { composer?.isIncognito ?? false }

    /// The shown chat changed (and at launch): restores its draft into the composer (none: empty composer).
    /// Returns the restored draft text so the host can mirror it (`WindowState.composerText`).
    @discardableResult
    public func show(chatID: String?) -> String? {
        let key = DraftStore.Key(chatID: chatID)
        guard key != shownKey, let composer else { return nil }
        if let old = shownKey {
            // Whatever the composer holds belongs to the chat being left (already pending from its last change).
            let current = Self.draft(of: composer)
            if current != lastSynced { store.update(current, for: old, incognito: incognito) }
            // Write it now: the debounce is one timer for the window, so typing in the next chat would otherwise
            // push the left chat's write past the 1 s bound. Enqueued, not waited for: the main thread never waits
            // for the database writer (AT-NFR-S3); until it commits the store restores the draft from memory.
            store.flushSoon()
        }
        shownKey = key
        let restored = store.draft(for: key, incognito: incognito) ?? .empty
        lastSynced = restored
        if Self.draft(of: composer) != restored {
            composer.restoreDraft(text: restored.text, attachments: restored.attachments.compactMap(Self.composerAttachment))
        }
        return restored.text
    }

    /// The composer's text or tray changed while `chatID` is shown.
    public func composerChanged(chatID: String?) {
        let key = DraftStore.Key(chatID: chatID)
        guard let composer else { return }
        guard key == shownKey else {
            show(chatID: chatID)  // a switch: restore the chat's draft, write nothing to it
            return
        }
        let current = Self.draft(of: composer)
        guard current != lastSynced else { return }
        lastSynced = current
        store.update(current, for: key, incognito: incognito)
    }

    /// A send from `chatID` (nil: the new chat): its draft is gone. The composer has already emptied itself.
    public func sent(chatID: String?) {
        let key = DraftStore.Key(chatID: chatID)
        store.clear(key, incognito: incognito)
        if key == shownKey { lastSynced = .empty }
    }

    /// Writes the pending drafts now (window close, tests).
    public func flush() { store.flush() }

    // MARK: Composer ⇄ draft

    static func draft(of composer: ComposerModel) -> DraftStore.Draft {
        DraftStore.Draft(text: composer.text, attachments: composer.attachments.map { a in
            switch a.kind {
            case .pastedText(let s): .pastedText(s)
            case .file(let url): .file(url.path)
            }
        })
    }

    static func composerAttachment(_ a: DraftStore.Attachment) -> ComposerAttachment? {
        switch a.kind {
        case .pastedText: a.text.map { ComposerAttachment(kind: .pastedText($0)) }
        case .file: a.path.map { ComposerAttachment(kind: .file(URL(fileURLWithPath: $0))) }
        }
    }
}
