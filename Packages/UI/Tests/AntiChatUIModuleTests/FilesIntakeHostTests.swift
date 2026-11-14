// AT-020 checks 1/3/4, in-process leg (M6.T01; the XCUITest FilesIntakeTests is pending Q-015): files added to the
// window's composer are read by the intake (tile spinner → ready with `tile.pages`), 21 files give 20 tiles + the
// `upload.tooMany` toast, a corrupt PDF ends as an error tile + `upload.failed.reason` toast, × removes a tile and its
// draft row, and a files-only send links the rows to the user message (shown on the bubble).
//   make test-unit FILTER=FilesIntakeHostTests
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct FilesIntakeHostTests {
    static let fixtures: URL = {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures")
    }()

    private func make() throws -> (WindowState, ChatSessions, ChatEnvironment) {
        let env = ChatEnvironment(
            database: try AppDatabase.inMemory(),
            engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok","delayMs":1}"#)),
            slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        return (state, ChatSessions(environment: env), env)
    }

    private func until(_ cond: () -> Bool) async -> Bool {
        for _ in 0..<1000 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
        return cond()
    }

    /// AT-020 audio leg (M3.T06, D-026 note 2): an M4A upload → `status.transcribing` with the real % → the transcript is
    /// the attachment's text and goes out with the message (the helper's transcription is a stand-in here; the real
    /// one runs in FileTranscriberRealTests).
    @Test func audioUploadBecomesATranscriptThatGoesOutWithTheMessage() async throws {
        let (state, sessions, env) = try make()
        let t = HostFakeTranscriber()
        sessions.audioTranscriber = t
        let composer = sessions.composer
        composer.addFiles([Self.fixtures.appendingPathComponent("audio/formats/clip.m4a")])
        #expect(await until { t.calls > 0 })
        #expect(await until { composer.intake.readyCount == 1 })
        let item = try #require(composer.intake.items[composer.attachments[0].id])
        #expect(AttachmentTileView.readyDetail(item) == CopyText(CopyKey("tile.audio"), ["duration": "2:01"]).string)
        #expect(AttachmentTileView.stateText(.transcribing(percent: 42.7), name: "clip.m4a", item: item)
            == CopyText(CopyKey("status.transcribing"), ["file": "clip.m4a", "percent": "42"]).string)
        sessions.stagedFileIDs = composer.intake.readyFileIDs(composer.attachments)
        state.send("summarise this", hasFiles: true, reduceMotion: true, turn: sessions.slots.startTurn)
        sessions.stagedFileIDs = []
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        #expect(await until { !m.isGenerating && m.messages.count == 2 })
        let userID = try #require(m.messages.first?.id)
        let rows = try AttachmentRepository(env.database).attachments(messageID: userID)
        #expect(rows.map(\.displayName) == ["clip.m4a"])
        let blob = try env.database.read { db in try FileBlobRecord.fetchOne(db, key: rows[0].blobID) }
        #expect(ExtractedTextStore.shared.markdown(for: try #require(blob))?.contains("[00:00:04] Second line.") == true)
    }

    @Test func filesBecomeReadyTilesAndGoOutWithTheMessage() async throws {
        let (state, sessions, env) = try make()
        let composer = sessions.composer
        let pdf = Self.fixtures.appendingPathComponent("docs/pdf/text-10p.pdf")
        let sheet = Self.fixtures.appendingPathComponent("docs/office/budget.xlsx")
        composer.addFiles([pdf, sheet])
        #expect(composer.attachments.count == 2)
        #expect(!composer.hasContent, "tiles still reading hold the send")
        #expect(await until { composer.intake.readyCount == 2 })
        #expect(composer.hasContent)
        let pdfItem = try #require(composer.intake.items[composer.attachments[0].id])
        #expect(AttachmentTileView.readyDetail(pdfItem) == CopyText(CopyKey("tile.pages"), ["count": "10"]).string)
        let sheetItem = try #require(composer.intake.items[composer.attachments[1].id])
        #expect(AttachmentTileView.readyDetail(sheetItem)?.contains("2 sheets") == true)
        // A files-only send (what LiveComposer's onSend does).
        sessions.stagedFileIDs = composer.intake.readyFileIDs(composer.attachments)
        state.send("", hasFiles: true, reduceMotion: true, turn: sessions.slots.startTurn)
        sessions.stagedFileIDs = []
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        #expect(await until { !m.isGenerating && m.messages.count == 2 })
        let userID = try #require(m.messages.first?.id)
        let rows = try AttachmentRepository(env.database).attachments(messageID: userID)
        #expect(rows.map(\.displayName).sorted() == ["budget.xlsx", "text-10p.pdf"])
        #expect(rows.allSatisfy { $0.extractState == .ready })
        #expect(m.messages.first?.attachments.map(\.displayName) == ["text-10p.pdf", "budget.xlsx"])
    }

    @Test func twentyOneFilesGiveTwentyTilesAndAToast() async throws {
        let (_, sessions, _) = try make()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("21-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try (0..<21).map { i -> URL in
            let u = dir.appendingPathComponent("note-\(i).txt")
            try Data("note \(i)".utf8).write(to: u)
            return u
        }
        sessions.composer.addFiles(urls)
        #expect(sessions.composer.attachments.count == 20)
        #expect(sessions.composer.intake.toast?.message == CopyText(CopyKey("upload.tooMany")))
    }

    @Test func corruptPDFShowsAnErrorTileAndToastAndXRemoves() async throws {
        let (_, sessions, env) = try make()
        let composer = sessions.composer
        composer.addFiles([Self.fixtures.appendingPathComponent("docs/pdf/corrupt.pdf"),
                           Self.fixtures.appendingPathComponent("docs/text/sample.md")])
        let bad = composer.attachments[0].id, good = composer.attachments[1].id
        #expect(await until { composer.intake.items[bad]?.state.isTerminalError == true && composer.intake.readyCount == 1 })
        #expect(composer.intake.toast?.message == CopyText(CopyKey("upload.failed.reason"), ["file": "corrupt.pdf"]))
        #expect(AttachmentTileView.stateText(.failed(reason: "x"), name: "corrupt.pdf", item: nil) == "Couldn't read this file")
        #expect(composer.intake.readyFileIDs(composer.attachments).count == 1, "only the ready tile is sent")
        let row = try #require(composer.intake.items[good]?.attachmentID)
        composer.removeAttachment(id: good)
        #expect(composer.attachments.count == 1)
        #expect(await until { (try? env.database.read { try AttachmentRecord.fetchOne($0, key: row) }) == nil })
    }

    @Test func tooLargeAndUnsupportedTilesNeverRead() async throws {
        let (_, sessions, env) = try make()
        let composer = sessions.composer
        composer.addFiles([Self.fixtures.appendingPathComponent("docs/office/legacy.doc")])
        let id = try #require(composer.attachments.first?.id)
        // The sniff runs in the intake actor (M6 review #15): the tile settles as unsupported without being read.
        #expect(await until { composer.intake.items[id]?.state == .unsupported(ext: "doc") })
        #expect(AttachmentTileView.stateText(.unsupported(ext: "doc"), name: "legacy.doc", item: nil) == "AntiChat can't read .doc files yet.")
        #expect(AttachmentTileView.stateText(.tooLarge(size: 600 * 1_000_000), name: "big.pdf", item: nil)
            .hasSuffix("limit 512 MB)") && !AttachmentTileView.stateText(.tooLarge(size: 600 * 1_000_000), name: "big.pdf", item: nil).contains("big.pdf"))
        #expect(try env.database.read { try AttachmentRecord.fetchCount($0) } == 0)
        #expect(!composer.hasContent)
    }
}

/// The helper's file transcription stand-in for the in-process legs.
final class HostFakeTranscriber: AudioTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var calls: Int { lock.withLock { n } }
    func isAvailable() async -> Bool { true }
    func transcribe(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscript {
        lock.withLock { n += 1 }
        for p in [0.0, 25, 50, 75, 100] { progress(p) }
        return AudioTranscript(text: "[00:00:00] Hello there.\n[00:00:04] Second line.", language: "en", engine: "parakeet")
    }
}
