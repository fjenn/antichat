// M6.T01 steps 4/7/8 (R-020 AC1/AC3/AC4): the composer tray's file intake. Every path in — `+ → add.files` (the open
// panel as a sheet), drag-and-drop anywhere on the window (`DropOverlay`), ⌘V of file URLs or images (`PasteHandler`)
// and draft restore — lands in `IntakeTray.add`: limits first (21 files → 20 tiles + `upload.tooMany` toast; > 512 MB →
// a too-large tile), then each file is copied, hashed, written as rows and read by `AttachmentIntake` off the main
// actor; its tile follows the state (reading % → ready / error + `upload.failed` toast / encrypted → password field).
// The window supplies the intake (`provider`): the app database + `<container>/Media`, or for an incognito chat the
// session's in-memory store + its temp dir. Sending takes the ready tiles' `attachment` row ids (`readyFileIDs`).
import AntiChatDesign
import AntiChatFoundation
import AntiChatKnowledge
import Foundation
import Observation

@MainActor
@Observable
public final class IntakeTray {
    /// Tile state by the composer attachment id (`ComposerAttachment.id` == `IntakeItem.id`).
    public private(set) var items: [UUID: IntakeItem] = [:]
    /// The toast of the last refusal / failure (IS-10); `ComposerView` shows it.
    public var toast: Toast?
    /// `(incognito) → intake` for the chat the composer sends to; nil = files are not read (tests without a window).
    @ObservationIgnored public var provider: (@MainActor (_ incognito: Bool) -> AttachmentIntake?)?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var intakes: [UUID: AttachmentIntake] = [:]
    /// Tile ids in the order they were added (the failure toast names files in tray order).
    @ObservationIgnored private var order: [UUID] = []

    public init() {}

    public func item(_ id: UUID) -> IntakeItem? { items[id] }

    /// Admits `urls` (limits only: the sniff runs in the intake actor, M6 review #15) and starts reading the accepted
    /// ones. Returns the tiles to add.
    func add(_ urls: [URL], existing: Int, incognito: Bool) -> [ComposerAttachment] {
        let admission = AttachmentIntake.admitLimits(urls, existing: existing)
        if !admission.rejected.isEmpty { toast = Toast(.warning, CopyText(CopyKey("upload.tooMany"))) }
        var tiles: [ComposerAttachment] = []
        for item in admission.items {
            items[item.id] = item
            order.append(item.id)
            tiles.append(ComposerAttachment(id: item.id, kind: .file(item.sourceURL)))
            start(item, incognito: incognito)
        }
        return tiles
    }

    /// A tile restored from a draft (same id): read again (dedup keeps one blob).
    func readmit(_ tile: ComposerAttachment, incognito: Bool) {
        guard let url = tile.fileURL, items[tile.id] == nil else { return }
        guard var item = AttachmentIntake.admitLimits([url]).items.first else { return }
        item = IntakeItem(id: tile.id, sourceURL: item.sourceURL, displayName: item.displayName, size: item.size,
                          sniff: item.sniff, state: item.state)
        items[tile.id] = item
        if !order.contains(tile.id) { order.append(tile.id) }
        start(item, incognito: incognito)
    }

    /// The encrypted tile's password (memory only: passed to the intake once, never stored).
    public func unlock(_ id: UUID, password: String) {
        guard let item = items[id], item.state == .encrypted, let intake = intakes[id] else { return }
        run(item, intake: intake, password: password)
    }

    /// × on a tile: stops its read and drops its draft row (the blob stays: other attachments may share it).
    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        order.removeAll { $0 == id }
        let row = items.removeValue(forKey: id)?.attachmentID
        if let row, let intake = intakes[id] { Task { await intake.discardDraftRow(row) } }
        intakes.removeValue(forKey: id)
    }

    /// Everything sent or cleared: forget the tiles (their rows now belong to the message).
    func clear() {
        // fix/t05-u2-u5: every send clears the tray (in its ack frame); an empty one is left untouched.
        if !items.isEmpty { items = [:] }
        order.removeAll()
        if !tasks.isEmpty { tasks = [:] }
        if !intakes.isEmpty { intakes = [:] }
    }

    /// `attachment` row ids of the ready tiles (and scans still being OCR'd, M6.T04 step 5), in tray order.
    func readyFileIDs(_ tray: [ComposerAttachment]) -> [String] {
        tray.compactMap { a in items[a.id].flatMap { $0.state.isSendable ? $0.attachmentID : nil } }
    }

    var isReading: Bool {
        items.values.contains {
            switch $0.state {
            case .reading, .transcribing: true
            default: false
            }
        }
    }
    /// Ready tiles with a row (a tile shown without an intake is never sent: nothing was read).
    var readyCount: Int { items.values.filter { $0.state.isSendable && $0.attachmentID != nil }.count }

    private func start(_ item: IntakeItem, incognito: Bool) {
        guard let intake = provider?(incognito) else {
            // No intake (a composer outside a window): the tile shows the file, nothing is read.
            let item = AttachmentIntake.sniffed(item)
            items[item.id] = item
            items[item.id]?.state = item.state == .reading(nil) ? .ready : item.state
            return
        }
        intakes[item.id] = intake
        run(item, intake: intake, password: nil)
    }

    private func run(_ item: IntakeItem, intake: AttachmentIntake, password: String?) {
        let id = item.id
        let sink: @Sendable (IntakeItem) -> Void = { [weak self] update in
            Task { @MainActor in self?.progress(update) }
        }
        tasks[id] = Task { [weak self] in
            let final = await intake.ingest(item, password: password, onUpdate: sink)
            // M6 review #20: the tile was removed while it was read: its row (if one got written) goes too.
            guard let self, self.items[id] != nil else {
                if let row = final.attachmentID { await intake.discardDraftRow(row) }
                return
            }
            #if DEBUG
            if self.holdForCapture { self.held[id] = final; return }  // VQ-M10: the probe shoots the reading tiles
            #endif
            self.finish(final)
        }
    }

    #if DEBUG
    /// VQ-M10 S-14 (vq-files-attach capture): while set, finished reads wait here so the tiles can be captured in
    /// their reading state (a 10-page PDF reads faster than one light + dark capture). DEBUG probes only.
    @ObservationIgnored public var holdForCapture = false
    @ObservationIgnored private var held: [UUID: IntakeItem] = [:]

    public func releaseCaptureHold() {
        holdForCapture = false
        let done = held
        held = [:]
        for final in done.values where items[final.id] != nil { finish(final) }
    }
    #endif

    private func finish(_ final: IntakeItem) {
        items[final.id] = final
        if case .failed(let reason) = final.state {
            AppLog.log(.ui, .notice, "intake failed for \(final.kind.rawValue): \(reason)")
        }
        // VQ-M10 round 65 (S-14, IS-10): the toast names every file in the tray that could not be read (failed, too
        // large, unsupported, locked), not only the last one: four error tiles had a toast naming one of them.
        if final.state.isTerminalError {
            let names = order.compactMap { items[$0] }.filter { $0.state.isTerminalError }.map(\.displayName)
            toast = Toast(.warning, Self.failedToast(names))
        }
    }

    /// A progress update (never overrides a finished state that arrived first).
    private func progress(_ update: IntakeItem) {
        guard let current = items[update.id] else { return }
        #if DEBUG
        if holdForCapture {  // VQ-M10: the intake's last onUpdate carries the finished state; held like the final
            switch update.state {
            case .reading, .scanning, .transcribing: break
            default: return
            }
        }
        #endif
        switch current.state {
        case .reading, .scanning, .transcribing: items[update.id] = update
        default: return
        }
    }

    /// `upload.failed` = the tile line ("Upload failed"), `upload.failed.reason` = the toast ("Couldn't read {file}.").
    static func failedToast(_ name: String) -> CopyText { CopyText(CopyKey("upload.failed.reason"), ["file": name]) }

    /// One file: `upload.failed.reason`; several: `upload.failed.many` ("Couldn't read 3 files: a, b and c."), the
    /// names joined for the current locale (up to 3, then "N more").
    static func failedToast(_ names: [String]) -> CopyText {
        guard names.count > 1 else { return failedToast(names.first ?? "") }
        var shown = Array(names.prefix(3))
        if names.count > 3 { shown.append(CopyText(CopyKey("upload.failed.more"), ["count": "\(names.count - 3)"]).string) }
        let list = ListFormatter.localizedString(byJoining: shown)
        return CopyText(CopyKey("upload.failed.many"), ["count": "\(names.count)", "files": list])
    }
}

extension AttachmentIntake {
    /// A draft tile removed before sending: its row (no message yet) goes; the blob stays.
    func discardDraftRow(_ id: String) {
        _ = try? database.write { db in
            try db.execute(sql: "DELETE FROM attachment WHERE id = ? AND message_id IS NULL", arguments: [id])
        }
    }
}
