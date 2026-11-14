// M4.T03 step 3 (R-285 AC6): app-side safety status from the installed detector files; the one counter a block leaves.
import AntiChatStorage
import CryptoKit
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct SafetyStatusTests {
    func files() throws -> (URL, [SafetyStatus.DetectorFile]) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = try ["a", "bb"].map { name -> SafetyStatus.DetectorFile in
            let u = dir.appending(path: name), d = Data(name.utf8)
            try d.write(to: u)
            return .init(path: u, sha256: SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined(), size: Int64(d.count))
        }
        return (dir, out)
    }

    @Test func availableMissingDamaged() throws {
        let (dir, f) = try files()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SafetyStatus.evaluate(f, installed: true, verify: true) == .available)
        #expect(SafetyStatus.evaluate(f, installed: false) == .missing(sizeBytes: 3))
        #expect(SafetyStatus.evaluate([], installed: true) == .missing(sizeBytes: 0))
        try Data("xx".utf8).write(to: f[1].path)  // same size, other bytes: only the hash check sees it
        #expect(SafetyStatus.evaluate(f, installed: true) == .available)
        #expect(SafetyStatus.evaluate(f, installed: true, verify: true) == .damaged(sizeBytes: 3))
        try FileManager.default.removeItem(at: f[0].path)
        #expect(SafetyStatus.evaluate(f, installed: true) == .damaged(sizeBytes: 3))
        #expect(SafetyStatus.damaged(sizeBytes: 3).repairBytes == 3 && SafetyStatus.available.repairBytes == nil)
    }

    @Test func blockIncrementsOnlyTheLocalCounter() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.write { try ChildSafetyCounter.recordBlock(in: $0) } == 1)
        #expect(try db.write { try ChildSafetyCounter.recordBlock(in: $0) } == 2)
        let rows = try db.read { try LocalCounterRecord.fetchAll($0) }
        #expect(rows.filter { $0.key == "child_safety_blocks" }.map(\.value) == [2])
    }
}
