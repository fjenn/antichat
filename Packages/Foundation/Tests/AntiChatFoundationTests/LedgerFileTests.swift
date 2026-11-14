// LedgerFile (the session ledger's file rule): a `start` creates the ledger, an `end` never recreates a ledger that
// Remove everything deleted (AT-NFR-D7: the RC Tart run found `Logs/AntiChat-Dev/sessions.jsonl` re-created by the
// exit line after Remove everything).
import Foundation
import Testing
@testable import AntiChatFoundation

@Suite struct LedgerFileTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
    }

    @Test func startCreatesFolderAndFileEndAppends() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("AntiChat-Dev/sessions.jsonl")
        #expect(LedgerFile.append(["event": "start", "pid": 1], to: url, create: true))
        #expect(LedgerFile.append(["event": "end", "pid": 1], to: url, create: false))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines == [#"{"event":"start","pid":1}"#, #"{"event":"end","pid":1}"#])
    }

    @Test func endNeverRecreatesADeletedLedgerOrItsFolder() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("AntiChat-Dev")
        let url = folder.appendingPathComponent("sessions.jsonl")
        #expect(LedgerFile.append(["event": "start", "pid": 2], to: url, create: true))
        try FileManager.default.removeItem(at: folder)  // Remove everything during the session
        #expect(!LedgerFile.append(["event": "end", "pid": 2], to: url, create: false))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
