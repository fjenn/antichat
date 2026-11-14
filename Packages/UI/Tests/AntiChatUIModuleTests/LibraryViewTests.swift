// M5.T13 (R-022 AC1–AC4, R-045 AC2; S-19; AT-022 in-process legs while XCUITest cannot run, Q-015): the Library page
// model — filters and search reload, Show in Library selects the file, open (clip → VideoViewer, picture/file → Quick
// Look), Open chat (source message reveal), Save As (copy), Show in Finder, Delete with confirmation (file gone), the
// Evil rule from the setting (nil follows Evil on/off) — and snapshots of the page states light/dark: grid (Evil shown,
// clip with length + sound icon + Evil badge), list, Videos tab, empty, empty search.
// Re-record: SNAPSHOT_TESTING_RECORD=all swift test --filter LibraryViewTests.
import AntiChatStorage
import AppKit
import Defaults
import GRDB
import SnapshotTesting
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct LibraryViewTests {
    struct Env {
        let db: AppDatabase
        let dir: URL
    }

    static func png(_ url: URL, _ color: NSColor) throws {
        let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in color.setFill(); r.fill(); return true }
        try NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
    }

    /// Fixed dates and files: a picture, a clip with sound (+ poster), a PDF, a sent photo, and an Evil picture.
    static func env() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("libview-\(UUID().uuidString)")
        let media = dir.appendingPathComponent("Media/2026")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        try png(media.appendingPathComponent("b1.png"), NSColor(calibratedRed: 0.95, green: 0.6, blue: 0.2, alpha: 1))
        try Data("mp4".utf8).write(to: media.appendingPathComponent("b2.mp4"))
        try png(media.appendingPathComponent("b2.poster.jpg"), NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.7, alpha: 1))
        try Data("%PDF-1.4".utf8).write(to: media.appendingPathComponent("b3.pdf"))
        try png(media.appendingPathComponent("b4.png"), NSColor(calibratedRed: 0.3, green: 0.7, blue: 0.4, alpha: 1))
        try png(media.appendingPathComponent("b5.png"), NSColor(calibratedRed: 0.6, green: 0.2, blue: 0.3, alpha: 1))
        let t0 = 1_800_000_000.0
        try db.write { d in
            for (c, mode) in [("n1", "normal"), ("e1", "evil")] {
                try d.execute(sql: "INSERT INTO chat (id, title, mode, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", arguments: [c, c, mode, t0, t0])
                try d.execute(sql: "INSERT INTO message (id, chat_id, role, created_at) VALUES (?, ?, 'user', ?)", arguments: ["m-\(c)", c, t0])
            }
            for (i, ext) in [(1, "png"), (2, "mp4"), (3, "pdf"), (4, "png"), (5, "png")] {
                try d.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES (?, ?, 2048, ?, ?, 'generated')",
                              arguments: ["b\(i)", "sha\(i)", media.appendingPathComponent("b\(i).\(ext)").path, t0])
            }
            let arts: [(String, String, String, String, String, String?, Double)] = [
                ("img", "n1", "image", "lighthouse.png", "b1", #"{"prompt":"a lighthouse at dusk"}"#, 100),
                ("vid", "n1", "video", "waves.mp4", "b2", #"{"prompt":"waves rolling onto a beach","frames":82,"fps":24,"sound":true}"#, 300),
                ("doc", "n1", "pdf", "Quarterly report.pdf", "b3", nil, 200),
                ("evil", "e1", "image", "dragon.png", "b5", #"{"prompt":"a dragon"}"#, 500),
            ]
            for (id, chat, kind, title, blob, spec, t) in arts {
                try d.execute(sql: "INSERT INTO artifact (id, chat_id, kind, title, created_at) VALUES (?, ?, ?, ?, ?)", arguments: [id, chat, kind, title, t0 + t])
                try d.execute(sql: "INSERT INTO artifact_version (id, artifact_id, n, blob_id, spec_json, created_by_message_id, created_at) VALUES (?, ?, 1, ?, ?, ?, ?)",
                              arguments: ["\(id)-v1", id, blob, spec, "m-\(chat)", t0 + t])
            }
            try d.execute(sql: "INSERT INTO attachment (id, message_id, blob_id, display_name, uti, created_at) VALUES ('att', 'm-n1', 'b4', 'holiday-photo.png', 'public.png', ?)",
                          arguments: [t0 + 400])
        }
        return Env(db: db, dir: dir)
    }

    final class Recorder: FileActionPerforming {
        var revealed: [URL] = []
        let dest: URL
        init(dest: URL) { self.dest = dest }
        func open(_ url: URL) -> Bool { true }
        func reveal(_ url: URL) { revealed.append(url) }
        func chooseSaveDestination(suggestedName: String, contentType: UTType) async -> URL? { dest.appendingPathComponent(suggestedName) }
    }

    @Test func modelFiltersSearchesAndActs() async throws {
        let e = try Self.env()
        let out = e.dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let rec = Recorder(dest: out)
        var opened: (String, String?)?
        let m = LibraryModel(database: e.db, actions: rec, evilEnabled: { false }) { opened = ($0, $1) }
        Defaults[.showEvilInLibrary] = nil
        defer { Defaults[.showEvilInLibrary] = nil }
        m.reload()
        #expect(m.items.map(\.id) == ["att", "vid", "doc", "img"], "newest first, Evil hidden (Evil off, setting unset)")
        m.filter = .videos
        #expect(m.items.map(\.id) == ["vid"])
        m.filter = .all
        m.query = "lighthouse"
        #expect(m.items.map(\.id) == ["img"] && m.isSearching)
        // Show in Library: clears filter and search, selects the file.
        m.filter = .files
        m.show(url: URL(fileURLWithPath: e.dir.appendingPathComponent("Media/2026/b4.png").path))
        #expect(m.filter == .all && m.query.isEmpty && m.selection == ["att"] && m.highlighted == "att")
        // Open: a clip → the viewer; a picture → Quick Look.
        let vid = try #require(m.items.first { $0.id == "vid" }), img = try #require(m.items.first { $0.id == "img" })
        m.open(vid)
        #expect(m.videoViewer?.path == vid.path && m.videoViewer?.name == "waves.mp4")
        m.open(img)
        #expect(m.quickLookURL?.path == img.path)
        // Open chat → the source message.
        m.openChat(img)
        #expect(opened?.0 == "n1" && opened?.1 == "m-n1")
        #expect(MessageReveal.shared.target(chatID: "n1", loaded: ["m-n1"]) == "m-n1")
        #expect(MessageReveal.shared.target(chatID: "other", loaded: ["m-n1"]) == nil)
        // Save As (a copy), Show in Finder.
        let saved = await m.saveAs(img)
        #expect(saved?.lastPathComponent == "lighthouse.png" && (try? Data(contentsOf: saved!)) == (try? Data(contentsOf: URL(fileURLWithPath: img.path))))
        m.reveal(img)
        #expect(rec.revealed == [URL(fileURLWithPath: img.path)])
        // Delete asks first; confirmed, the file leaves the disk.
        m.requestDelete(img)
        #expect(m.pendingDelete == img && FileManager.default.fileExists(atPath: img.path))
        m.confirmDelete()
        #expect(m.pendingDelete == nil && !FileManager.default.fileExists(atPath: img.path) && !m.items.contains { $0.id == "img" })
        #expect(CopyText(CopyKey("library.delete.confirm"), ["name": "lighthouse.png"]).string
                == "Delete lighthouse.png? This also removes the file from your Mac.")
    }

    @Test func evilFollowsTheSettingAndTheEnableState() throws {
        let e = try Self.env()
        var evilOn = false
        let m = LibraryModel(database: e.db, evilEnabled: { evilOn })
        defer { Defaults[.showEvilInLibrary] = nil }
        Defaults[.showEvilInLibrary] = nil
        m.reload()
        #expect(!m.items.contains { $0.isEvil } && !m.showsEvil)
        evilOn = true
        m.reload()
        #expect(m.items.first?.id == "evil" && m.items.first?.isEvil == true, "default on once Evil is enabled")
        Defaults[.showEvilInLibrary] = false
        m.reload()
        #expect(!m.items.contains { $0.isEvil }, "the user's Off sticks")
        evilOn = false
        Defaults[.showEvilInLibrary] = true
        m.reload()
        #expect(m.items.contains { $0.isEvil }, "the user's On sticks")
        #expect(CopyKey("badge.evil").string() == "Evil")
    }

    @Test func snapshotsOfThePageStates() throws {
        LibraryThumbnail.liveThumbnails = false
        defer { LibraryThumbnail.liveThumbnails = true; Defaults[.showEvilInLibrary] = nil }
        let e = try Self.env()
        Defaults[.showEvilInLibrary] = true
        func model(_ f: (LibraryModel) -> Void = { _ in }) -> LibraryModel {
            let m = LibraryModel(database: e.db, evilEnabled: { true })
            f(m)
            m.reload()
            return m
        }
        let empty = try AppDatabase.onDisk(at: e.dir.appendingPathComponent("empty.sqlite"))
        let cases: [(String, LibraryModel)] = [
            ("grid", model()),
            ("list", model { $0.layout = .list }),
            ("videos", model { $0.filter = .videos }),
            ("emptySearch", model { $0.query = "zebra" }),
            ("empty", LibraryModel(database: empty, evilEnabled: { false })),
        ]
        for (name, m) in cases {
            for look in Look.allCases {
                let v = LibraryView(model: m).frame(height: 520)
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!).environment(\.locale, Locale(identifier: "en_US"))
                    .frame(width: 860, alignment: .leading).padding(Spacing.space4).background(Color.surfaceCanvas)
                // The window rig (SnapshotWindow: backing scale pinned at 2×; converged; two fresh renders must agree,
                // see `renderAgreed`): the plain-NSWindow rig took the scale of whichever screen AppKit picked and
                // captured once, and the search field came out taller once (placeholder 2 pt higher, grid-light/-dark).
                // The window is never key and ignores the real pointer (fix/test-flakes: the placeholder moved 1 px
                // with the field's focus state in grid/videos under the full run).
                assertSnapshot(of: renderAgreed { render(v, look: look, converge: true) },
                               as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(name)-\(look.rawValue)",
                               testName: "library")
            }
        }
    }
}
}  // extension WindowSuites
