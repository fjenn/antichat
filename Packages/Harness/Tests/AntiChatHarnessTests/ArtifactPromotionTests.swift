// M6.T13 (R-016 AC1, AC3, AC4; AT-016 checks 1, 3, 4, 5 in process): OutputPromotion's rule (40 lines inline, 41
// promote; html / jsx / tsx / svg / mermaid / vega-lite always), titles and fences; a finished reply's promoted blocks
// become artifacts (one per block, spec_json sha256, created_by_message_id), an interrupted reply promotes nothing, a
// repeated block is not saved twice, and an Edit selection / Fix turn makes version 2 of the same artifact with only
// the selected span changed and version 1 kept.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

private func pyBlock(_ n: Int, tweak: Bool = false) -> String {
    var lines = ["def checklist_total(items):", "    \"\"\"Sum the hours.\"\"\"", "    total = 0"]
    var i = 0
    while lines.count < n - 1 { i += 1; lines.append("    total += items.get('step_\(i)', 0)") }
    lines.append("    return total")
    if tweak { for k in 9...11 { lines[k] = lines[k].replacingOccurrences(of: "items.get(", with: "items.get_hours(") } }
    return lines.joined(separator: "\n")
}

private func fence(_ lang: String, _ body: String) -> String { "Here it is:\n\n```\(lang)\n\(body)\n```\n" }

/// A ScriptedEngine segment replying `text` (one delta per line).
private func segment(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let v = String(data: try! JSONSerialization.data(withJSONObject: [String(line) + "\n"]), encoding: .utf8)!
        return #"{"t":"textDelta","v":\#(v.dropFirst().dropLast()),"delayMs":0}"#
    }.joined(separator: "\n")
}

@Suite struct OutputPromotionTests {
    @Test func fortyLinesStayInlineFortyOnePromote() {
        #expect(OutputPromotion.classify(language: "python", code: pyBlock(40) + "\n") == nil)
        let b = OutputPromotion.classify(language: "python", code: pyBlock(41) + "\n")
        #expect(b?.kind == .code && b?.lineCount == 41 && b?.ext == "py" && b?.title == "Python code")
        #expect(OutputPromotion.classify(language: "", code: (1...41).map { "line \($0)" }.joined(separator: "\n"))?.kind == .doc)
        #expect(OutputPromotion.classify(language: "markdown", code: "# Plan\n" + (1...41).map { "- \($0)" }.joined(separator: "\n"))?.title == "Plan")
    }

    @Test func webKindsAlwaysPromote() {
        let html = OutputPromotion.classify(language: "html", code: "<html><head><title>Launch checklist</title></head></html>")
        #expect(html?.kind == .html && html?.react == false && html?.title == "Launch checklist" && html?.filename == "Launch checklist.html")
        let jsx = OutputPromotion.classify(language: "jsx", code: "export default function Counter() { return <b/> }")
        #expect(jsx?.kind == .html && jsx?.react == true && jsx?.title == "Counter" && jsx?.ext == "jsx")
        #expect(OutputPromotion.classify(language: "tsx", code: "const A = () => <i/>; export default A")?.title == "A")
        let reactPage = OutputPromotion.classify(language: "html", code: "<script src=\"https://unpkg.com/react@18/umd/react.production.min.js\"></script><script type=\"text/babel\">ReactDOM.render(<b/>, root)</script>")
        #expect(reactPage?.react == true)
        let svg = OutputPromotion.classify(language: "svg", code: "<svg><title>Sunrise</title></svg>")
        #expect(svg?.kind == .svg && svg?.title == "Sunrise")
        #expect(OutputPromotion.classify(language: "xml", code: "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")?.kind == .svg)
        #expect(OutputPromotion.classify(language: "xml", code: "<note/>") == nil)
        let mmd = OutputPromotion.classify(language: "mermaid", code: "flowchart TD\n A --> B")
        #expect(mmd?.kind == .mermaid && mmd?.title == "Flowchart" && mmd?.ext == "mmd")
        let vl = OutputPromotion.classify(language: "json", code: #"{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","title":"Quarterly revenue","mark":"bar"}"#)
        #expect(vl?.kind == .chart && vl?.title == "Quarterly revenue" && vl?.filename == "Quarterly revenue.vl.json")
        #expect(OutputPromotion.classify(language: "json", code: #"{"a":1}"#) == nil, "plain JSON stays inline")
        #expect(OutputPromotion.classify(language: "vega-lite", code: #"{"mark":"bar"}"#)?.title == "Chart")
        #expect(OutputPromotion.classify(language: "html", code: "  \n") == nil, "empty blocks never promote")
    }

    @Test func fencesAndHashes() {
        let md = """
            Intro
            ````markdown
            ```python
            inner
            ```
            ````
            ~~~svg
            <svg/>
            ~~~
              ```html
              <p>indented</p>
              ```
            ```mermaid
            graph LR
            """
        let blocks = OutputPromotion.fencedBlocks(in: md)
        #expect(blocks.map(\.language) == ["markdown", "svg", "html", "mermaid"])
        #expect(blocks[0].code == "```python\ninner\n```", "a longer fence keeps inner fences")
        #expect(blocks[2].code == "<p>indented</p>", "fence indent removed")
        #expect(blocks[3].code == "graph LR", "an unclosed fence runs to the end")
        #expect(OutputPromotion.sha256("a\n") == OutputPromotion.sha256("a"), "trailing newlines do not change the hash")
        #expect(OutputPromotion.promotions(in: md).map(\.kind) == [.svg, .html, .mermaid])
    }

    @Test func editPromptsAndSpanCheck() {
        let r = ArtifactEditRequest(artifactID: "a1", title: "page.html", language: "html", source: "<p>x</p>",
                                    action: .editSelection(selection: "x", instruction: "make it bold"))
        #expect(ArtifactEditService.prompt(for: r).hasPrefix("Edit only this part of page.html: «x» — instruction: make it bold"))
        #expect(ArtifactEditService.context(for: r) == "page.html (current version):\n```html\n<p>x</p>\n```")
        let f = ArtifactEditRequest(artifactID: "a1", title: "broken.html", language: "html", source: "s", action: .fix(message: "boom"))
        #expect(ArtifactEditService.prompt(for: f).hasPrefix("Fix this error in broken.html: boom"))
        #expect(ArtifactEditService.changesOnlySelection(original: "a b c", revised: "a B! c", selection: "b"))
        #expect(!ArtifactEditService.changesOnlySelection(original: "a b c", revised: "A B c", selection: "b"))
        #expect(!ArtifactEditService.changesOnlySelection(original: "a b c", revised: "a b c", selection: "b"))
    }
}

@Suite struct ArtifactPromotionTurnTests {
    final class Rig {
        var last: String?
        let db: AppDatabase
        let controller: TurnController
        let log: UpdateLog
        let chatID: String
        let media: URL

        init(script: String) throws {
            db = try AppDatabase.inMemory()
            media = FileManager.default.temporaryDirectory.appendingPathComponent("promote-\(UUID().uuidString)")
            let engine = InProcessScriptedEngine(script: try EngineScript(text: script))
            let env = ChatEnvironment(database: db, engine: engine, slot: { .scripted("inline") })
            chatID = try ChatRepository(db).create(title: "artifacts").id
            controller = env.controller(chatID: chatID)
            log = UpdateLog(controller)
        }

        func send(_ text: String) async throws -> (String, TurnResult) {
            await controller.setOutputStore(ArtifactStore(database: db, mediaRoot: media, incognito: false))
            let a = StorageID.make()
            await controller.start(.send(userID: StorageID.make(), text: text, parentID: last), assistantID: a)
            last = a
            return (a, try await log.waitFinished(a))
        }

        func artifacts() throws -> [ArtifactRecord] {
            try db.read { try ArtifactRecord.order(Column("created_at")).fetchAll($0) }
        }
    }

    @Test func finishedReplyPromotesEachBlock() async throws {
        let reply = "Two things.\n\n```html\n<title>Launch checklist</title><p>hi</p>\n```\n\nand\n\n```python\n\(pyBlock(40))\n```\n\n```svg\n<svg><title>Sunrise</title></svg>\n```\n"
        let rig = try Rig(script: segment(reply))
        let (a, r) = try await rig.send("make them")
        #expect(r.status == .done)
        let rows = try rig.artifacts()
        #expect(rows.map(\.kind) == ["html", "svg"], "the 40-line block stays inline")
        #expect(rows.map(\.title) == ["Launch checklist.html", "Sunrise.svg"])
        let v = try rig.db.read { try ArtifactVersionRecord.fetchAll($0) }
        #expect(v.allSatisfy { $0.createdByMessageID == a && $0.n == 1 })
        let ref = try #require(ArtifactPromotionService.lookup(sha256: OutputPromotion.sha256("<svg><title>Sunrise</title></svg>"),
                                                               chatID: rig.chatID, database: rig.db))
        #expect(ref.kind == .svg && ref.version == 1 && ref.versions.count == 1)
        #expect(try String(contentsOfFile: ref.versions[0].path, encoding: .utf8) == "<svg><title>Sunrise</title></svg>")
        #expect(try ChatFilesQuery(rig.db).files(chatID: rig.chatID).filter { $0.origin == .produced }.count == 2,
                "Outputs lists the promoted artifacts")
    }

    @Test func interruptedReplyPromotesNothingAndRepeatsAreNotSavedTwice() async throws {
        let block = fence("mermaid", "flowchart TD\n A --> B")
        let rig = try Rig(script: segment(block) + "\n{\"t\":\"turn\"}\n" + segment(block)
                          + "\n{\"t\":\"turn\"}\n" + segment("```html\n<p>cut") + "\n{\"t\":\"error\",\"code\":\"engine.restarted\"}")
        _ = try await rig.send("diagram")
        _ = try await rig.send("again")
        #expect(try rig.artifacts().count == 1, "the same diagram again is the same artifact")
        let (_, r) = try await rig.send("page")
        #expect(r.status != .done)
        #expect(try rig.artifacts().count == 1, "an interrupted reply promotes nothing")
    }

    @Test func editSelectionMakesVersionTwoWithOnlyTheSpanChanged() async throws {
        let v1 = pyBlock(60), v2 = pyBlock(60, tweak: true)
        let rig = try Rig(script: segment(fence("python", v1)) + "\n{\"t\":\"turn\"}\n" + segment(fence("python", v2)))
        _ = try await rig.send("helper")
        let ref = try #require(ArtifactPromotionService.lookup(sha256: OutputPromotion.sha256(v1), chatID: rig.chatID, database: rig.db))
        let lines = v1.components(separatedBy: "\n")
        let selection = lines[9...11].joined(separator: "\n")
        let request = ArtifactEditRequest(artifactID: ref.artifactID, title: ref.title, language: "python", source: v1,
                                          action: .editSelection(selection: selection, instruction: "use get_hours"))
        await rig.controller.setRevisesNextTurn(request.artifactID)
        _ = try await rig.send(ArtifactEditService.prompt(for: request))
        #expect(try rig.artifacts().count == 1, "no new artifact: a new version")
        let after = try #require(ArtifactPromotionService.lookup(sha256: OutputPromotion.sha256(v2), chatID: rig.chatID, database: rig.db))
        #expect(after.artifactID == ref.artifactID && after.version == 2 && after.versions.map(\.n) == [1, 2])
        let stored1 = try String(contentsOfFile: after.versions[0].path, encoding: .utf8)
        let stored2 = try String(contentsOfFile: after.versions[1].path, encoding: .utf8)
        #expect(stored1 == v1, "version 1 kept")
        #expect(ArtifactEditService.changesOnlySelection(original: stored1, revised: stored2, selection: selection))
        let versions = try ArtifactRepository(rig.db).versions(artifactID: ref.artifactID)
        #expect(versions[1].parentVersionID == versions[0].id)
    }
}
