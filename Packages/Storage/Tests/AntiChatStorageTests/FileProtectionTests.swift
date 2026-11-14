// M8.T08 step 8 (NFR-PR4; AT-NFR-PR4): directories 0700, the database triple, backups and exports 0600; a stricter
// mode is kept; symlinks are never followed; missing paths are skipped (nothing is created).
import Foundation
import Testing
@testable import AntiChatStorage

@Suite struct FileProtectionTests {
    private func scratch() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fileprot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func make(_ url: URL, dir: Bool = false, mode: mode_t) throws {
        if dir {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("x".utf8).write(to: url)
        }
        #expect(chmod(url.path, mode) == 0)
    }

    @Test func directoriesBecome700AndDatabaseFiles600() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("AntiChat"), caches = root.appendingPathComponent("Caches/AntiChat")
        let logs = root.appendingPathComponent("Logs/AntiChat"), backups = container.appendingPathComponent("Backups")
        for d in [container, caches, logs, backups] { try make(d, dir: true, mode: 0o755) }
        let db = container.appendingPathComponent("antichat.sqlite")
        for suffix in ["", "-wal", "-shm"] { try make(URL(fileURLWithPath: db.path + suffix), mode: 0o644) }
        let backup = backups.appendingPathComponent("daily-20261107.sqlite")
        try make(backup, mode: 0o644)
        let log = logs.appendingPathComponent("antichat.log")
        try make(log, mode: 0o644)

        let report = FileProtection.ensure(directories: [container, caches, logs], database: db, fileDirectories: [backups, logs])
        #expect(report.failures.isEmpty)
        for d in [container, caches, logs, backups] { #expect(FileProtection.mode(d.path) == 0o700, "\(d.path)") }
        for f in [db.path, db.path + "-wal", db.path + "-shm", backup.path, log.path] {
            #expect(FileProtection.mode(f) == 0o600, "\(f)")
        }
        // Idempotent: a second launch changes nothing.
        let again = FileProtection.ensure(directories: [container, caches, logs], database: db, fileDirectories: [backups, logs])
        #expect(again.directories.isEmpty && again.files.isEmpty)
    }

    @Test func stricterModesStayAndMissingPathsAreSkipped() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let strict = root.appendingPathComponent("strict")
        try make(strict, dir: true, mode: 0o500)
        let file = root.appendingPathComponent("antichat.sqlite")
        try make(file, mode: 0o400)
        let missing = root.appendingPathComponent("nope")
        let r = FileProtection.ensure(directories: [strict, missing], database: file)
        #expect(r.failures.isEmpty)
        #expect(FileProtection.mode(strict.path) == 0o500)
        #expect(FileProtection.mode(file.path) == 0o400)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        chmod(strict.path, 0o700)
    }

    @Test func symlinksAreNeverFollowed() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("external-models")
        try make(target, dir: true, mode: 0o755)
        let dir = root.appendingPathComponent("Backups")
        try make(dir, dir: true, mode: 0o700)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: target)
        FileProtection.ensure(directories: [], database: nil, fileDirectories: [dir])
        #expect(FileProtection.mode(target.path) == 0o755)
    }

    @Test func protectFileMakesAnExportPrivate() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("AntiChat Export.zip")
        try make(zip, mode: 0o644)
        #expect(FileProtection.protectFile(zip))
        #expect(FileProtection.mode(zip.path) == 0o600)
    }
}
