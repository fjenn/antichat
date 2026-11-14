// M6 review #15: dropping files into the tray never sniffs them on the main actor (PDFDocument opens, OLE scans): the
// tiles appear with the limits checked only, and the intake actor sniffs, reads and settles each one.
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.enabled(if: FileFixtures.available), .isolatedSettings) struct IntakeTrayReviewTests {
    @Test func addSniffsOffTheMainActor() async throws {
        let dir = try FileFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tray = IntakeTray()
        let intake = AttachmentIntake(database: try AppDatabase.inMemory(), mediaRoot: dir, incognito: true)
        tray.provider = { _ in intake }
        let pdf = FileFixtures.root!.appendingPathComponent("docs/pdf/text-10p.pdf")
        let doc = FileFixtures.root!.appendingPathComponent("docs/office/legacy.doc")
        let tiles = tray.add([pdf, doc], existing: 0, incognito: true)
        #expect(tiles.count == 2)
        #expect(tiles.allSatisfy { tray.item($0.id)?.sniff == nil }, "add() sniffed on the main actor")
        for _ in 0..<600 where tiles.contains(where: { tray.item($0.id).map { !$0.state.isSendable && !$0.state.isTerminalError } ?? true }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(tray.item(tiles[0].id)?.state == .ready && tray.item(tiles[0].id)?.sniff?.kind == .pdf)
        #expect(tray.item(tiles[1].id)?.state == .unsupported(ext: "doc"))
    }
}
