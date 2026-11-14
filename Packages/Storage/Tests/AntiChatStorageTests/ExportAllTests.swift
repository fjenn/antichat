// M8.T07 AT-093 (R-093 AC1): the export-all zip. Manifest fields, the entry list (chats JSON + Markdown, projects with
// their files, memory, settings, media), the media toggle, no secrets in any entry, the Evil header in chats-md,
// cancel deletes the partial file, and a newer format version is refused on import.
//   make test-unit FILTER=ExportAllTests
import AntiChatFoundation
import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import AntiChatStorage

/// Runs a repo Python tool (`python3 -I <script> <args>`); fails the test on a non-zero exit.
@discardableResult
func runPython(_ script: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-I", repoRoot.appendingPathComponent(script).path] + args
    p.currentDirectoryURL = repoRoot
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw StorageError.invalidExport("\(script) exit \(p.terminationStatus): \(String(decoding: errData, as: UTF8.self))")
    }
    return String(decoding: data, as: UTF8.self)
}

/// gen-chats.py into `dir/seed.sqlite` (media under `dir/seed.sqlite-media`).
func generateChats(in dir: URL, _ args: [String]) throws -> URL {
    let out = dir.appendingPathComponent("seed.sqlite")
    let seed = fixturesRoot.appendingPathComponent("chats/big-10k/seed.json")
    var all = args + ["--out", out.path]
    if FileManager.default.fileExists(atPath: seed.path) { all += ["--seed", seed.path] }
    try runPython("tools/fixtures/gen-chats.py", all)
    return out
}

func zipEntries(_ url: URL) throws -> [String: Data] {
    let a = try Archive(url: url, accessMode: .read)
    var out: [String: Data] = [:]
    for e in a where e.type == .file {
        var d = Data()
        _ = try a.extract(e) { d.append($0) }
        out[e.path] = d
    }
    return out
}

@Suite("ExportAllTests", .serialized) struct ExportAllTests {
    /// Review fix (M8.T16): an export zip's blob names never pick where a file lands; bytes must hash to the name.
    @Test func importerAcceptsOnlyRealSHA256Names() throws {
        #expect(AntiChatImporter.isSHA256(String(repeating: "a1", count: 32)))
        #expect(!AntiChatImporter.isSHA256("../../../../Library/LaunchAgents/x"))
        #expect(!AntiChatImporter.isSHA256(String(repeating: "A1", count: 32)), "lower-case hex only")
        #expect(!AntiChatImporter.isSHA256(String(repeating: "a", count: 63)))
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(try AntiChatImporter.sha256(of: f) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    static let small = ["--chats", "12", "--long", "0:0", "--turns", "0", "--projects", "1", "--project-files", "2",
                        "--memories", "6", "--memory-topics", "3", "--evil", "1", "--images", "3"]

    func export(includeMedia: Bool, settings: [String: Any]? = nil) throws -> (URL, [String: Data], ExportResult) {
        let dir = try tempContainer("export")
        let db = try AppDatabase.onDisk(at: try generateChats(in: dir, Self.small))
        let url = dir.appendingPathComponent(AntiChatExportFormat.fileName())
        let result = try ExportAllWriter(database: db).write(
            to: url, options: ExportOptions(includeMedia: includeMedia, settingsJSON: settings.map(ExportSettings.json), appVersion: "test"))
        return (url, try zipEntries(url), result)
    }

    @Test func manifestAndEntries() throws {
        let (url, entries, result) = try export(includeMedia: true, settings: ["textSize": 2, "theme": "dark"])
        #expect(url.lastPathComponent.range(of: #"^AntiChat-Export-\d{4}-\d{2}-\d{2}-\d{4}\.zip$"#, options: .regularExpression) != nil)
        let manifest = try #require(entries["manifest.json"])
        let m = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        #expect(m["format"] as? String == "antichat-export")
        #expect(m["version"] as? Int == 1)
        #expect(m["app_version"] as? String == "test")
        #expect(m["schema_version"] as? String == Migrations.identifiers.last)
        #expect(m["created_at"] is String)
        #expect(m["includes_media"] as? Bool == true)
        let counts = try #require(m["counts"] as? [String: Int])
        #expect(counts["chats"] == 12 && counts["projects"] == 1 && counts["memories"] == 6 && counts["media"] == 5)
        #expect(counts["messages"] == result.counts.messages && result.counts.messages > 0)

        let names = Set(entries.keys)
        #expect(names.filter { $0.hasPrefix("chats/") && $0.hasSuffix(".json") }.count == 12)
        #expect(names.filter { $0.hasPrefix("chats-md/") && $0.hasSuffix(".md") }.count == 12)
        #expect(names.filter { $0.hasPrefix("projects/") && $0.hasSuffix("/project.json") }.count == 1)
        #expect(names.filter { $0.hasPrefix("projects/") && $0.contains("/files/") }.count == 2)
        #expect(names.filter { $0.hasPrefix("projects/") && $0.hasSuffix("/instructions.md") }.count == 1)
        #expect(names.contains("memory/memory.json"))
        #expect(names.filter { $0.hasPrefix("memory/") && $0.hasSuffix(".md") }.count == 3)
        #expect(names.contains("settings/defaults.json"))
        #expect(names.filter { $0.hasPrefix("media/") && $0.hasSuffix(".png") }.count == 3)
        #expect(names.contains("media/blobs.json"))
        // Every chat JSON carries the tree (messages with parent/active child, parts, attachments).
        let chat = try #require(entries.first { $0.key.hasPrefix("chats/") }?.value)
        let doc = try #require(try JSONSerialization.jsonObject(with: chat) as? [String: Any])
        let first = try #require((doc["messages"] as? [[String: Any]])?.first)
        for k in ["id", "parent_id", "active_child_id", "role", "status", "model_id", "created_at", "provenance_json"] {
            #expect(first.keys.contains(k), "message column \(k)")
        }
        #expect(((doc["parts"] as? [[String: Any]])?.first?.keys.contains("untrusted")) == true)
        #expect((doc["chat"] as? [String: Any])?.keys.contains("memory_enabled") == true)
    }

    @Test func mediaOff() throws {
        let (_, entries, result) = try export(includeMedia: false)
        #expect(!entries.keys.contains { $0.hasPrefix("media/") && $0 != "media/blobs.json" })
        #expect(!entries.keys.contains { $0.contains("/files/") })
        #expect(!entries.keys.contains("settings/defaults.json"))
        #expect(result.counts.media == 0)
        let m = try #require(try JSONSerialization.jsonObject(with: entries["manifest.json"]!) as? [String: Any])
        #expect(m["includes_media"] as? Bool == false)
    }

    @Test func noSecretsAndEvilHeader() throws {
        let relayID = "dev-relay-install-7f3e2a"
        let settings: [String: Any] = ["relay.installID": relayID, "mcp.token": "sk-live-123", "projectBookmark": "x",
                                       "NSWindow Frame main": "0 0 10 10", "theme": "dark", "blob": Data([1, 2])]
        let (_, entries, _) = try export(includeMedia: true, settings: settings)
        for (name, data) in entries where !name.hasPrefix("media/") || name.hasSuffix(".json") {
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains(relayID), "\(name)")
            #expect(!text.contains("sk-live-123"), "\(name)")
            #expect(!text.contains("app.antichat.mcp."), "\(name)")
        }
        let s = try #require(try JSONSerialization.jsonObject(with: entries["settings/defaults.json"]!) as? [String: Any])
        #expect(s.keys.sorted() == ["theme"])
        let evil = entries.filter { $0.key.hasPrefix("chats-md/") }.map { String(decoding: $0.value, as: UTF8.self) }
            .filter { $0.contains("mode: evil") }
        #expect(evil.count == 1)
        #expect(evil.first?.hasPrefix("> Evil mode\n") == true)
        #expect(entries.filter { $0.key.hasPrefix("chats-md/") }.map { String(decoding: $0.value, as: UTF8.self) }
            .filter { $0.hasPrefix("> Evil mode") }.count == 1)
    }

    @Test func cancelLeavesNoFile() throws {
        let dir = try tempContainer("export-cancel")
        let db = try AppDatabase.onDisk(at: try generateChats(in: dir, Self.small))
        let url = dir.appendingPathComponent("out.zip")
        var calls = 0
        let r = try ExportAllWriter(database: db).write(to: url, options: ExportOptions(), isCancelled: { calls += 1; return calls > 3 })
        #expect(r.cancelled)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func newerVersionRefused() throws {
        let dir = try tempContainer("export-newer")
        let url = dir.appendingPathComponent("newer.zip")
        let a = try Archive(url: url, accessMode: .create)
        let m = Data(#"{"format":"antichat-export","version":2,"schema_version":"v99_x"}"#.utf8)
        try a.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(m.count)) { pos, size in m.subdata(in: Int(pos)..<Int(pos) + size) }
        #expect(ChatImporter.detect(url) == .antichat)
        let db = try AppDatabase.inMemory()
        #expect(throws: ImportError.newerExport) {
            try AntiChatImporter(database: db, mediaRoot: dir).run(url)
        }
    }

    @Test func settingsRestoreFilters() throws {
        let d = UserDefaults.inMemory()
        let n = ExportSettings.restore(Data(#"{"theme":"dark","relay.installID":"x","consentAdult":true}"#.utf8), into: d)
        #expect(n == 1)
        #expect(d.string(forKey: "theme") == "dark")
        #expect(d.object(forKey: "relay.installID") == nil && d.object(forKey: "consentAdult") == nil)
    }
}
