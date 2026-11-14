// M3 review P2-6: voice temp audio lives in per-process directories; the launch sweep removes what dead processes left
// (and stale loose files of the older flat layout), never a live process's files.
import Foundation
import Testing
@testable import AntiChatFoundation

@Suite struct VoiceTempTests {
    @Test func sweepRemovesOnlyWhatDeadProcessesLeft() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voicetemp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let mine = VoiceTemp.directory("area", root: root)
        try Data("x".utf8).write(to: mine.appendingPathComponent("live.m4a"))
        // A crashed process's directory (owner pid that cannot exist) and one without an owner file.
        let dead = root.appendingPathComponent("area/99999999", isDirectory: true)
        try fm.createDirectory(at: dead, withIntermediateDirectories: true)
        try Data("99999999".utf8).write(to: dead.appendingPathComponent(IncognitoTemp.ownerFile))
        try Data("x".utf8).write(to: dead.appendingPathComponent("left.m4a"))
        let orphan = root.appendingPathComponent("area/orphan", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        // Loose files of the flat layout: an old one goes, a fresh one stays (a run of an older build may own it).
        let old = root.appendingPathComponent("area/old.wav"), fresh = root.appendingPathComponent("area/fresh.wav")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: fresh)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: old.path)

        let removed = Set(VoiceTemp.sweep("area", root: root).map(\.lastPathComponent))
        #expect(removed == ["99999999", "orphan", "old.wav"])
        #expect(fm.fileExists(atPath: mine.appendingPathComponent("live.m4a").path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

    /// fix/review P7: a dead process's directory whose pid now runs another process (pid 1, launchd, here) is swept:
    /// the owner's recorded start time is not that process's.
    @Test func sweepRemovesADeadOwnersDirectoryWhosePidWasReused() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voicetemp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let reused = root.appendingPathComponent("area/1", isDirectory: true)
        try fm.createDirectory(at: reused, withIntermediateDirectories: true)
        try Data("1 123456".utf8).write(to: reused.appendingPathComponent(IncognitoTemp.ownerFile))
        try Data("x".utf8).write(to: reused.appendingPathComponent("left.m4a"))
        let mine = VoiceTemp.directory("area", root: root)
        #expect(Set(VoiceTemp.sweep("area", root: root).map(\.lastPathComponent)) == ["1"])
        #expect(fm.fileExists(atPath: mine.path))
    }

    /// fix/review P7: a directory left under this process's pid by a dead process that had the same pid is emptied
    /// when this process claims it (its files are not adopted as live).
    @Test func claimingAReusedPidsDirectoryDropsTheDeadOwnersFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voicetemp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let stale = root.appendingPathComponent("area/\(getpid())", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("\(getpid()) 123456".utf8).write(to: stale.appendingPathComponent(IncognitoTemp.ownerFile))
        try Data("x".utf8).write(to: stale.appendingPathComponent("left.m4a"))
        #expect(!IncognitoTemp.isLive(stale), "same pid, another start time: a dead owner")
        let dir = VoiceTemp.directory("area", root: root)
        #expect(dir.standardizedFileURL == stale.standardizedFileURL)
        #expect(!fm.fileExists(atPath: stale.appendingPathComponent("left.m4a").path))
        #expect(IncognitoTemp.isLive(dir))
        // Claimed: later calls keep this process's own files.
        try Data("x".utf8).write(to: dir.appendingPathComponent("mine.m4a"))
        _ = VoiceTemp.directory("area", root: root)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("mine.m4a").path))
    }
}

/// fix/review P7: incognito temp liveness is the owner's pid and start time, so a reused pid is not a live owner.
@Suite struct IncognitoTempLivenessTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("incognitotemp-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func ownerIsPidAndStartTime() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = IncognitoTemp.make("x", in: root)
        let owner = try String(contentsOf: dir.appendingPathComponent(IncognitoTemp.ownerFile), encoding: .utf8)
        let start = try #require(IncognitoTemp.startTime(of: getpid()))
        #expect(owner == "\(getpid()) \(start)")
        #expect(start > 0)
        #expect(IncognitoTemp.isLive(dir))
        #expect(IncognitoTemp.isOwnedByThisProcess(dir))
    }

    @Test func aReusedPidIsNotALiveOwner() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func dir(_ name: String, owner: String) throws -> URL {
            let d = root.appendingPathComponent(IncognitoTemp.prefix + name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(owner.utf8).write(to: d.appendingPathComponent(IncognitoTemp.ownerFile))
            return d
        }
        // pid 1 (launchd: alive, root's, so kill(1, 0) gives EPERM) with another process's start time: a dead owner.
        #expect(!IncognitoTemp.isLive(try dir("rootpid", owner: "1 123456")))
        // This process's pid with another start time: a dead owner whose pid this process got.
        #expect(!IncognitoTemp.isLive(try dir("mypid", owner: "\(getpid()) 123456")))
        // pid 1 with its real start time: live.
        let launchd = try #require(IncognitoTemp.startTime(of: 1))
        #expect(IncognitoTemp.isLive(try dir("launchd", owner: "1 \(launchd)")))
        // A process that has exited: not live.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        #expect(!IncognitoTemp.isLive(try dir("exited", owner: "\(p.processIdentifier) 1")))
        #expect(IncognitoTemp.startTime(of: 99_999_999) == nil)
    }

    /// An older build's owner file (pid only): live while that pid's process started before the file was written.
    @Test func pidOnlyOwnerFilesUseTheFileDate() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let legacy = root.appendingPathComponent(IncognitoTemp.prefix + "legacy", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let owner = legacy.appendingPathComponent(IncognitoTemp.ownerFile)
        try Data("\(getpid())".utf8).write(to: owner)
        #expect(IncognitoTemp.isLive(legacy), "written by this (running) process after it started")
        // Written long before this process started: a dead process with the same pid wrote it.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: owner.path)
        #expect(!IncognitoTemp.isLive(legacy))
    }
}
