// AT-M0-11 (docs/prd/M0.md, M0.T11 step 4): import every fixture under fixtures/chats/{chatgpt-export,claude-export}/
// into an in-memory GRDB database, re-read the DB, rebuild {nodes, edges, active_leaf, active_path} and compare
// with the hand-derived `*.expected.json` exactly. Set AT_M0_11_OUT=<dir> to also write a per-fixture summary.
// M1.T04: runs on the v1 schema (`AppDatabase.inMemory()`, `TreeImporter`); shared helpers in TreeFixtures.swift.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

private let fixtureDirs = ["chats/chatgpt-export", "chats/claude-export"]

@Suite("ImportRoundTripTests") struct ImportRoundTripTests {
    @Test func fixturesPresent() {
        let files = expectedFiles(in: fixtureDirs)
        #expect(files.filter { $0.hasPrefix("chats/chatgpt-export/") }.count >= 3, "\(files)")
        #expect(files.filter { $0.hasPrefix("chats/claude-export/") }.count >= 1, "\(files)")
    }

    @Test(arguments: expectedFiles(in: fixtureDirs))
    func roundTrip(expectedPath: String) throws {
        let expectedURL = fixturesRoot.appendingPathComponent(expectedPath)
        let expected = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? [String: Any])
        let fixtureName = try #require(expected["fixture"] as? String)
        let fixtureURL = expectedURL.deletingLastPathComponent().appendingPathComponent(fixtureName)
        let want = (expected["conversations"] as? [[String: Any]] ?? []).map(TreeShape.init(expected:))

        let queue = try AppDatabase.inMemory()
        let chatIds = try TreeImporter.importExport(data: Data(contentsOf: fixtureURL), into: queue)
        let got = try queue.read { db in try readShapes(db) }

        #expect(chatIds.count == want.count, "conversation count")
        var report: [[String: Any]] = []
        for expectedShape in want {
            let match = got.first { $0.shape.id == expectedShape.id }
            let diffs = match.map { $0.shape.differences(from: expectedShape) } ?? ["conversation \(expectedShape.id) not imported"]
            #expect(diffs.isEmpty, "\(fixtureName) \(expectedShape.id): \(diffs)")
            if let match {
                #expect(match.downPath == match.shape.activePath, "active_child_id chain != parent_id path")
                #expect(match.emptyMessages == 0, "messages without a non-empty part")
            }
            report.append([
                "conversation": expectedShape.id, "nodes": match?.shape.nodes ?? -1,
                "edges": match?.shape.edges.count ?? -1, "branch_points": branchPoints(match?.shape),
                "active_path": match?.shape.activePath.count ?? -1, "recovered": match?.shape.recovered.count ?? -1,
                "differences": diffs.count,
            ])
        }
        if let out = ProcessInfo.processInfo.environment["AT_M0_11_OUT"] {
            let dir = URL(fileURLWithPath: out).appendingPathComponent("fixtures")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: ["fixture": "\(expectedPath.replacingOccurrences(of: ".expected.json", with: ""))",
                                 "file": fixtureName, "conversations": report],
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appendingPathComponent(expectedURL.lastPathComponent.replacingOccurrences(
                of: ".expected.json", with: ".result.json")))
        }
    }

    private func branchPoints(_ shape: TreeShape?) -> Int {
        guard let shape else { return -1 }
        var counts: [String: Int] = [:]
        for edge in shape.edges { counts[edge[1] ?? "<root>", default: 0] += 1 }
        return counts.values.filter { $0 > 1 }.count
    }
}

/// Repair rules not covered by the fixtures (M0.md T11 failure modes), on inline exports. Nested so that
/// `--filter ImportRoundTripTests` (the AT-M0-11 command) runs it too.
extension ImportRoundTripTests { @Suite struct TreeRepair {
    private func shapes(_ json: String) throws -> [TreeShape] {
        let queue = try AppDatabase.inMemory()
        try TreeImporter.importExport(data: Data(json.utf8), into: queue)
        return try queue.read { db in try readShapes(db).map(\.shape) }
    }

    private func node(_ id: String, _ parent: String?, _ children: [String], role: String = "user", text: String = "x") -> String {
        let p = parent.map { "\"\($0)\"" } ?? "null"
        let c = children.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            "\(id)": {"id": "\(id)", "parent": \(p), "children": [\(c)],
              "message": {"id": "\(id)", "author": {"role": "\(role)"}, "content": {"content_type": "text", "parts": ["\(text)"]}}}
            """
    }

    @Test func chatGPTCycleIsBrokenAndReattachedToRoot() throws {
        // r → a; b ↔ c form a cycle with no path to r.
        let json = """
            [{"id": "cyc", "title": "cycle", "current_node": "a", "mapping": {
            \(node("r", nil, ["a"])), \(node("a", "r", [], role: "assistant")),
            \(node("b", "c", ["c"])), \(node("c", "b", ["b"], role: "assistant"))}}]
            """
        let shape = try #require(try shapes(json).first)
        #expect(shape.nodes == 4)
        // Walking up from b: b → c → b; b repeats first, so b's parent edge is cut and b goes under r.
        #expect(shape.edges == [["a", "r"], ["b", "r"], ["c", "b"], ["r", nil]])
        #expect(shape.recovered == ["b"])
        #expect(shape.activePath == ["r", "a"])
    }

    @Test func chatGPTHiddenCurrentNodeFallsBackToUsableAncestor() throws {
        let json = """
            [{"id": "h", "title": "hidden", "current_node": "s", "mapping": {
            \(node("u", nil, ["v"])), \(node("v", "u", ["s"], role: "assistant")),
            "s": {"id": "s", "parent": "v", "children": [], "message": {"id": "s", "author": {"role": "system"},
              "content": {"content_type": "text", "parts": ["sys"]}}}}}]
            """
        let shape = try #require(try shapes(json).first)
        #expect(shape.nodes == 2)
        #expect(shape.activeLeaf == "v")
    }

    @Test func claudeWithoutParentIdsIsFlattenedWithNotice() throws {
        let json = """
            [{"uuid": "flat", "name": "old", "chat_messages": [
              {"uuid": "m1", "sender": "human", "text": "hi"},
              {"uuid": "m2", "sender": "assistant", "text": "hello"},
              {"uuid": "m3", "sender": "human", "text": "bye"}]}]
            """
        let shape = try #require(try shapes(json).first)
        #expect(shape.edges == [["m1", nil], ["m2", "m1"], ["m3", "m2"]])
        #expect(shape.activePath == ["m1", "m2", "m3"])
        let queue = try AppDatabase.inMemory()
        try TreeImporter.importExport(data: Data(json.utf8), into: queue)
        let notice = try queue.read { db in try String.fetchOne(db, sql: "SELECT import_notice FROM chat") }
        #expect(notice == "flattened_no_parent_ids")
    }
} }
