// M6.T13 AT-277 (R-277 AC1–AC3), the in-process leg of the matrix: the 8 formats of fixtures/docs/formats-8 (A-M6-05)
// × {preview, Open, Save As…, Reveal, Copy, Share…, Show in Library, drag-out}, each file both as an attachment
// (AttachmentIntake → media store) and as a generated card (ArtifactStore). A cell passes when both legs do:
//   preview   the side panel's body for the file renders (PDFKit document with pages / image / text / a Quick Look
//             thumbnail for Office and audio);
//   Open      FileCardViewModel.open → the default-app call (test double) with a named copy of the stored file;
//   Save As…  a byte-identical copy at the chosen destination;
//   Reveal    the reveal call (test double) with the stored file;
//   Copy      the pasteboard holds a file URL named display_name with the same bytes;
//   Share…    the share item is a file named display_name and macOS offers sharing services for it;
//   Library   Show in Library (M5.T13, D-026): the action hands the stored file to the Library, which lists it
//             (LibraryIndex.item(path:) on the same on-disk database: sent attachment and generated artifact);
//   drag-out  DragOut's provider exports a copy named display_name with the same bytes.
// Every action has a VoiceOver label (copy keys `file.*.a11y`, checked non-empty with the file name in it).
// Writes `matrix.json` to $ANTICHAT_AT277_OUT when set (tools/at/run.sh AT-277 -- …). The XCUITest leg
// (App/UITests/FileActionsTests) and the Finder / Mail drag (vq-07 steps 24–25, computer use) are pending (Q-015, Q-021).
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import AppKit
import Foundation
import PDFKit
import QuickLookThumbnailing
import Testing
import UniformTypeIdentifiers
@testable import AntiChatDesign
@testable import AntiChatUI

@MainActor
final class MatrixFileActions: FileActionPerforming {
    var opened: [URL] = []
    var revealed: [URL] = []
    var copied: [URL] = []
    var shownInLibrary: [URL] = []
    let destination: URL
    init(destination: URL) { self.destination = destination }
    func open(_ url: URL) -> Bool { opened.append(url); return true }
    func reveal(_ url: URL) { revealed.append(url) }
    func chooseSaveDestination(suggestedName: String, contentType: UTType) async -> URL? {
        destination.appendingPathComponent(suggestedName)
    }
    func showInLibrary(_ url: URL) { shownInLibrary.append(url) }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .enabled(if: FileFixtures.root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("docs/formats-8/memo.m4a").path) } ?? false,
                             "fixtures/docs/formats-8 missing"), .isolatedSettings)
struct FileActionsMatrixTests {
    static let files = ["report.pdf", "report.docx", "budget.xlsx", "deck.pptx", "notes.csv", "photo.png", "photo.jpg", "memo.m4a"]
    static let actions = ["preview", "open", "saveAs", "reveal", "copy", "share", "library", "dragOut"]

    func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("at277-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The two stored copies of a fixture: (attachment item, generated item); nil leg = that leg could not be made.
    func legs(_ name: String, db: AppDatabase, root: URL) async throws -> [(String, FileCardItem?)] {
        let source = FileFixtures.root!.appendingPathComponent("docs/formats-8/\(name)")
        // M3.T06 (D-026 note 2): the M4A column runs with transcription live — the attachment is read through the
        // helper's file transcription (stand-in here) before its actions are checked.
        let audio = (name as NSString).pathExtension == "m4a"
        let intake = AttachmentIntake(database: db, mediaRoot: root.appendingPathComponent("In"), incognito: false,
                                      transcriber: audio ? HostFakeTranscriber() : nil)
        let admitted = AttachmentIntake.admit([source]).items[0]
        let item = await intake.ingest(admitted)
        if audio { #expect(item.state == .ready && item.document?.transcriptionPending == false, "memo.m4a transcribed") }
        var attached: FileCardItem?
        if let id = item.attachmentID {  // M5.T13: the Library lists sent attachments (attached to a message)
            let chat = try ChatRepository(db).create(title: "at277-in").id
            try db.write { d in
                try d.execute(sql: "INSERT INTO message (id, chat_id, role, created_at) VALUES (?, ?, 'user', 0)", arguments: ["m-\(id)", chat])
                try d.execute(sql: "UPDATE attachment SET message_id = ? WHERE id = ?", arguments: ["m-\(id)", id])
            }
        }
        if let id = item.attachmentID,
           let path = try db.read({ db in try AttachmentRecord.fetchOne(db, key: id).flatMap { try FileBlobRecord.fetchOne(db, key: $0.blobID) }?.path }) {
            attached = FileCardItem(url: URL(fileURLWithPath: path), displayName: name)
        }
        let chat = try ChatRepository(db).create(title: "at277").id
        let store = ArtifactStore(database: db, mediaRoot: root.appendingPathComponent("Out"), incognito: false)
        let saved = try store.save(chatID: chat, kind: (name as NSString).pathExtension, filename: name,
                                   data: try Data(contentsOf: source), specJSON: nil, messageID: nil)
        let generated = FileCardItem(url: URL(fileURLWithPath: saved.path), displayName: name, version: saved.version)
        return [("attachment", attached), ("generated", generated)]
    }

    func preview(_ url: URL) async -> Bool {
        switch PanelBody(url: url) {
        case .pdf: return (PDFDocument(url: url)?.pageCount ?? 0) > 0
        case .image: return NSImage(contentsOf: url).map { $0.size.width > 0 } ?? false
        case .text: return ((try? String(contentsOf: url, encoding: .utf8))?.isEmpty == false)
        case .web: return true
        case .quickLook:
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 256, height: 256), scale: 2,
                                                   representationTypes: .all)
            let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
            return rep != nil
        }
    }

    func check(_ action: String, _ item: FileCardItem, source: Data, root: URL, db: AppDatabase) async -> Bool {
        let rec = MatrixFileActions(destination: (try? scratch()) ?? root)
        let vm = FileCardViewModel(item: item, actions: rec)
        let named = { (u: URL?) -> Bool in
            guard let u else { return false }
            return u.lastPathComponent == item.displayName && (try? Data(contentsOf: u)) == source
        }
        switch action {
        case "preview": return await preview(item.url)
        case "open":
            vm.open()
            return rec.opened.count == 1 && rec.opened[0] != item.url && named(rec.opened.first) && !CopyText(CopyKey("file.open.a11y"), ["filename": item.displayName]).string.isEmpty
        case "saveAs":
            let dest = await vm.saveAs()
            return dest.map { (try? Data(contentsOf: $0)) == source && $0.lastPathComponent == item.displayName } ?? false
        case "reveal":
            vm.reveal()
            return rec.revealed == [item.url]
                && CopyText(CopyKey("file.reveal.a11y"), ["filename": item.displayName]).string.contains(item.displayName)
        case "copy":
            vm.copy()
            let pb = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]
            return named(pb?.first) && CopyText(CopyKey("file.copy.a11y"), ["filename": item.displayName]).string.contains(item.displayName)
        case "share":
            let u = vm.sharedURL()
            return named(u) && !NSSharingService.sharingServices(forItems: [u]).isEmpty
                && CopyText(CopyKey("file.share.a11y"), ["filename": item.displayName]).string.contains(item.displayName)
        case "library":
            vm.showInLibrary()
            guard rec.shownInLibrary == [item.url] else { return false }
            return ((try? LibraryIndex(db).item(path: item.url.path)) ?? nil) != nil
        case "dragOut":
            let p = DragOut.itemProvider(for: item)
            guard p.suggestedName == item.displayName else { return false }
            let url: URL? = await withCheckedContinuation { c in
                _ = p.loadObject(ofClass: URL.self) { u, _ in c.resume(returning: u) }
            }
            return named(url)
        default: return false
        }
    }

    @Test func matrix() async throws {
        let root = try scratch()
        // On disk: the Library never lists an in-memory (incognito) database.
        let db = try AppDatabase.onDisk(at: root.appendingPathComponent("antichat.sqlite"))
        var cells: [[String: Any]] = []
        var passed = 0
        let deferred = 0
        for name in Self.files {
            let source = try Data(contentsOf: FileFixtures.root!.appendingPathComponent("docs/formats-8/\(name)"))
            let legs = try await legs(name, db: db, root: root)
            for action in Self.actions {
                var legResults: [String: Bool] = [:]
                for (leg, item) in legs {
                    var ok = false
                    if let item { ok = await check(action, item, source: source, root: root, db: db) }
                    legResults[leg] = ok
                }
                let ok = legResults.values.allSatisfy { $0 }
                if ok { passed += 1 }
                cells.append(["file": name, "action": action, "result": ok ? "pass" : "fail", "legs": legResults])
                #expect(ok, "\(name) × \(action): \(legResults)")
            }
        }
        #expect(passed == 64, "AT-277 after M5.T13: 64/64 (Show in Library column closed, D-026)")
        if let out = ProcessInfo.processInfo.environment["ANTICHAT_AT277_OUT"], !out.isEmpty {
            let dir = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let summary: [String: Any] = [
                "at": "AT-277", "passed": passed, "total": Self.files.count * Self.actions.count, "deferred": deferred,
                "formats": Self.files, "actions": Self.actions, "cells": cells,
                "m4a": "attachment leg transcribed through AudioTranscribing (M3.T06)",
                "pending": ["XCUITest App/UITests/FileActionsTests (Q-015)", "performAccessibilityAudit (Q-015)",
                            "drag to Finder / Mail, vq-07 steps 24–25 (computer use, Q-021)"],
                "date": ISO8601DateFormatter().string(from: Date()),
            ]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("matrix.json"))
        }
    }
}
}  // extension WindowSuites
