// M7.T12 step 1: archive paths that escape (`../`, absolute), symlink entries and the 500-file limit are refused
// before anything is extracted; nothing is written outside the import's temp folder.
import Foundation
import OsaurusVendored
import Testing
@testable import AntiChatTools

@Suite struct ZipSlipTests {
    func refused(_ name: String) -> (any Error)? {
        do {
            let c = try SkillImporter.inspect(SkillFixtures.bad.appendingPathComponent(name))
            c.discard()
            return nil
        } catch { return error }
    }

    @Test func dotDotEntryIsRefusedBeforeExtraction() throws {
        let escaped = FileManager.default.temporaryDirectory.appendingPathComponent("zip-slip-escaped.txt")
        try? FileManager.default.removeItem(at: escaped)
        let e = try #require(refused("zip-slip.zip"))
        guard case SkillFileError.archiveEntryEscapes(let path)? = e as? SkillFileError else {
            Issue.record("expected archiveEntryEscapes, got \(e)"); return
        }
        #expect(path == "../zip-slip-escaped.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test func absolutePathEntryIsRefused() throws {
        let e = try #require(refused("absolute-path.zip"))
        guard case SkillFileError.archiveEntryEscapes? = e as? SkillFileError else { Issue.record("got \(e)"); return }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/antichat-absolute-path.txt"))
    }

    @Test func symlinkEntryIsRefused() throws {
        let e = try #require(refused("symlink-entry.zip"))
        guard case SkillFileError.archiveEntryUnsupported? = e as? SkillFileError else { Issue.record("got \(e)"); return }
    }

    @Test func symlinkInFolderIsRefused() throws {
        let dir = SkillFixtures.bad.appendingPathComponent("symlink/linked-skill")
        do {
            let c = try SkillImporter.inspect(dir)
            c.discard()
            Issue.record("a folder with a symlink was accepted")
        } catch let e as SkillFileError {
            guard case .archiveEntryUnsupported = e else { Issue.record("got \(e)"); return }
        }
    }

    @Test func overFiveHundredFilesIsRefused() throws {
        let e = try #require(refused("too-many-files.zip"))
        guard case SkillFileError.archiveEntryLimitExceeded(let limit)? = e as? SkillFileError else { Issue.record("got \(e)"); return }
        #expect(limit == 500)
    }

    @Test func policyLimitsAreTheTaskValues() {
        #expect(SkillImporter.policy.maxArchiveBytes == 50 * 1024 * 1024)
        #expect(SkillImporter.policy.maxEntryBytes == 10 * 1024 * 1024)
        #expect(SkillImporter.policy.maxEntryCount == 500)
    }

    /// A single file over 10 MB is refused (folder form; the zip form uses the same per-entry check).
    @Test func oversizedFileIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString)/big-skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try "---\nname: big-skill\ndescription: d\n---\nx".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try Data(count: 10 * 1024 * 1024 + 1).write(to: dir.appendingPathComponent("blob.bin"))
        #expect(throws: SkillFileError.self) { try SkillImporter.inspect(dir) }
    }
}
