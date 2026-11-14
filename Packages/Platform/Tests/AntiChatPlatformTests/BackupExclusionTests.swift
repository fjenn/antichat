// AT-NFR-D9 — M2.T10: the Models folder is excluded from Time Machine at creation and on every launch; the database
// (chats, settings) is not.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite struct BackupExclusionTests {
    /// The exclusion flag is eventually consistent on macOS 26: `setResourceValues` returns before a read sees the new
    /// value (a fresh URL, getxattr and an uncached read all lag, a few ms; under load it failed this test once). So each
    /// check after a write waits for the expected value (5 s cap) instead of reading once. Every write did land:
    /// 6000 runs of this sequence, the final `true` always settled, ≤ 35 ms.
    @Test func modelsExcludedDatabaseIncluded() async throws {
        let dir = DL.tempDir("tm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let models = ModelsDirectory.default(container: dir)
        try models.create()
        try await until(5) { models.isExcludedFromBackup }
        #expect(models.isExcludedFromBackup)
        let dbURL = dir.appending(path: "antichat.sqlite")
        _ = try AppDatabase.onDisk(at: dbURL)
        #expect((try dbURL.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == false)
        // Re-applied on launch even if something cleared it.
        var u = models.root
        var v = URLResourceValues(); v.isExcludedFromBackup = false
        try u.setResourceValues(v)
        try await until(5) { !models.isExcludedFromBackup }
        #expect(!models.isExcludedFromBackup)
        try models.create()
        try await until(5) { models.isExcludedFromBackup }
        #expect(models.isExcludedFromBackup)
        ATLog.write("AT-NFR-D9", "unit.log", "BackupExclusion: Models excluded at creation and re-applied on launch; antichat.sqlite included")
    }
}
