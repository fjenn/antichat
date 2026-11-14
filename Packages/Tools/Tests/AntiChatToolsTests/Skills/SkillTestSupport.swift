// M7.T12 test support: a store in a temp folder over an in-memory database, and the skill fixtures.
import AntiChatStorage
import Foundation
@testable import AntiChatTools

struct TempSkillStore {
    let dir: URL
    let store: SkillStore
    let database: AppDatabase

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-test-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase.inMemory()
        store = SkillStore(root: dir.appendingPathComponent("Skills", isDirectory: true), database: database)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

enum SkillFixtures {
    static let examplesSHA = "2c5958e"
    static var examples: URL { ToolsFixtures.url("skills/agentskills-examples@\(examplesSHA)") }
    static var bad: URL { ToolsFixtures.url("skills/bad") }

    /// The example skill folders (sorted).
    static func exampleFolders() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The repository root (build/at/… evidence).
    static var repoRoot: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { dir.deleteLastPathComponent() }
        return dir
    }

    /// Byte-for-byte equal trees (relative paths + contents).
    static func sameTree(_ a: URL, _ b: URL) -> Bool {
        let fa = SkillStore.files(in: a), fb = SkillStore.files(in: b)
        guard fa.map(\.relativePath) == fb.map(\.relativePath) else { return false }
        return fa.allSatisfy { f in
            (try? Data(contentsOf: a.appendingPathComponent(f.relativePath))) == (try? Data(contentsOf: b.appendingPathComponent(f.relativePath)))
        }
    }
}
