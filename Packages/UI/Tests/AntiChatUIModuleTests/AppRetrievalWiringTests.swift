// The composition root's retrieval wiring (AppRetrievalWiring.attach, the function AntiChatApp.init calls) on the
// app's real engine type: every retrieval consumer the app builds must come out with its embedder. Two misses of this
// class shipped green before — the router / ⌘K embedder (M2.T26: `as? EngineClient` on a supervisor) and the document
// embedder (nothing attached it: in-app document and project search was keyword-only; the benches pass their own).
// The source scan below fails when a new retrieval consumer is constructed with a literal `embedder: nil` or without
// naming its embedder.
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.serialized, .isolatedSettings) struct AppRetrievalWiringTests {
    @Test func everyRetrievalConsumerOfTheAppGetsItsEmbedder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        // The app's engine type (never connected here: the slots are nil, so no request reaches a helper).
        let engine = EngineSupervisorClient(appBuild: "test")
        let env = ChatEnvironment(database: db, engine: engine, slot: { .scripted("inline") })
        let previousSearch = SemanticSearch.shared
        defer {
            SemanticSearch.shared = previousSearch
            WebSearchTools.useEmbedder(nil)
        }
        let make = try #require(AppRetrievalWiring.helperFactory(for: env.engine), "the app's engine yields no embedder")
        let route = DeferredRouteEmbedding()
        AppRetrievalWiring.attach(database: db, make: make, embed: { nil }, rerank: { nil }, routeEmbedding: route,
                                  decisionModel: nil)

        #expect(SemanticSearch.shared?.embedder != nil, "⌘K semantic index")
        #expect(SemanticSearch.shared?.retriever.embedder != nil, "⌘K hybrid retriever")
        #expect(route.isSet, "semantic pre-router")
        #expect(WebSearchTools.embedder != nil, "web page ranking")
        #expect(MemoryRuntime.for(db).embedder != nil, "memory decider / snapshot")
        #expect(MemoryRuntime.for(db).snapshots.embedder != nil, "memory snapshot ranking")
        #expect(MemoryRuntime.for(db).decider.embedder != nil, "memory decider")
        #expect(MemorySettingsViewModel(database: db).review.embedder != nil, "memory review service")
        #expect(DocumentEmbedding.for(db).embedder != nil, "document embedder")
        // The chat turn path the app builds (attachment excerpts M6.T02, project retrieval M8.T05).
        let controller = env.controller(chatID: StorageID.make())
        #expect(await controller.documentEmbedder != nil, "turn controller document search")
        // Project files (ProjectsModel: add / link / folder rescans).
        #expect(await ProjectsModel.indexer(db).embedder != nil, "project file vectors")

        // Incognito (an in-memory store) never embeds (R-247).
        let incognito = ChatEnvironment(database: try AppDatabase.inMemory(), engine: engine, isIncognito: true,
                                        slot: { .scripted("inline") })
        DocumentEmbedding.for(incognito.database).attach(make({ nil }, { nil }))
        #expect(await incognito.controller(chatID: StorageID.make()).documentEmbedder == nil)
    }

    /// Every construction of a retrieval consumer in the product sources names its embedder, never a literal nil
    /// (a line marked `retrieval-wiring:` documents an intended exception).
    @Test func noRetrievalConsumerIsBuiltWithoutItsEmbedder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let consumers = ["HybridRetriever", "ProjectRetriever", "ProjectFileIndexer", "DocumentContextAssembler",
                         "DocumentIndexer", "MemoryUpdateDecider", "MemoryReviewService", "MemorySnapshotBuilder",
                         "SemanticSearch"]
        var dirs = [root.appendingPathComponent("App/AntiChat")]
        let packages = root.appendingPathComponent("Packages")
        for p in try FileManager.default.contentsOfDirectory(atPath: packages.path) {
            dirs.append(packages.appendingPathComponent(p).appendingPathComponent("Sources"))
        }
        var checked = 0
        var problems: [String] = []
        for dir in dirs {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for name in consumers {
                    for call in Self.calls(of: name, in: text) {
                        checked += 1
                        let ok = call.args.contains("embedder:") && !call.args.contains("embedder: nil)")
                            && !call.args.contains("embedder: nil,")
                        if !ok && !call.line.contains("retrieval-wiring:") {
                            problems.append("\(url.lastPathComponent): \(name)(\(call.args))")
                        }
                    }
                }
            }
        }
        #expect(checked >= 8, "the scan found the app's consumers (\(checked))")
        #expect(problems.isEmpty, "retrieval consumers without their embedder:\n\(problems.joined(separator: "\n"))")
    }

    /// `Name(` calls (not declarations / doc comments) with their balanced argument text and source line.
    static func calls(of name: String, in text: String) -> [(args: String, line: String)] {
        var out: [(String, String)] = []
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: name + "(", range: search) {
            search = r.upperBound..<text.endIndex
            if r.lowerBound > text.startIndex {
                let prev = text[text.index(before: r.lowerBound)]
                if prev.isLetter || prev.isNumber || prev == "_" { continue }
            }
            let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let lineEnd = text[r.lowerBound...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[lineStart..<lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
            let before = text[lineStart..<r.lowerBound]
            if before.contains("func ") || before.contains("//") || before.contains("`") { continue }
            var depth = 1, i = r.upperBound
            while i < text.endIndex, depth > 0 {
                if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            }
            out.append((String(text[r.upperBound..<text.index(before: i)]) + ")", line))
        }
        return out
    }
}
