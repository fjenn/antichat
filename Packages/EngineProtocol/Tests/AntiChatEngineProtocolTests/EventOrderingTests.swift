// M1.T13 AT-229 unit leg: `make test-unit FILTER=EventOrderingTests` — R-229 AC1 (only the seven event kinds;
// usage before done; toolCallDone after its deltas; nothing after the terminal) on hand-built streams and on every
// committed ScriptedEngine script replayed through EngineScriptPlayer, and R-229 AC2 (ChatRequest carries messages,
// tools, tool_choice, sampling, reasoning{on,budget}, images[] and the requestID cancel token: Codable round trip
// with every field set).
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngineProtocol

@Suite struct EventOrderingTests {
    static let u = EngineEvent.usage(Usage(promptTokens: 3, completionTokens: 2))

    @Test func sevenKindsExactly() {
        // Exhaustive switch in EventOrdering.kind: adding an eighth case fails to compile; the names are the contract.
        #expect(EventOrdering.kinds.count == 7)
        let all: [EngineEvent] = [
            .reasoningDelta("r"), .textDelta("t"), .toolCallDelta(id: "a", name: "f", argsFragment: "{"),
            .toolCallDone(id: "a", name: "f", argsJSON: "{}"), Self.u, .done(.stop), .error(.engine("x")),
        ]
        #expect(Set(all.map(EventOrdering.kind)) == Set(EventOrdering.kinds))
    }

    @Test func conformantStreamsPass() {
        let plain: [EngineEvent] = [.reasoningDelta("hm"), .textDelta("Hi"), Self.u, .done(.stop)]
        #expect(EventOrdering.violations(plain).isEmpty)
        let tool: [EngineEvent] = [
            .toolCallDelta(id: "c1", name: "get_time", argsFragment: "{\"tz\":"),
            .toolCallDelta(id: "c1", name: nil, argsFragment: "\"UTC\"}"),
            .toolCallDone(id: "c1", name: "get_time", argsJSON: "{\"tz\":\"UTC\"}"), Self.u, .done(.toolCalls),
        ]
        #expect(EventOrdering.violations(tool).isEmpty)
        // Cancelled: usage optional, open tool deltas allowed.
        #expect(EventOrdering.violations([.textDelta("par"), .done(.cancelled)]).isEmpty)
        #expect(EventOrdering.violations([.toolCallDelta(id: "c", name: "f", argsFragment: "{"), .done(.cancelled)]).isEmpty)
        #expect(EventOrdering.violations([.textDelta("x"), .error(.engine("boom"))]).isEmpty)
    }

    @Test func violationsAreFound() {
        #expect(!EventOrdering.violations([]).isEmpty)
        #expect(!EventOrdering.violations([.textDelta("no terminal")]).isEmpty)
        #expect(!EventOrdering.violations([.done(.stop), .textDelta("after")]).isEmpty)
        #expect(!EventOrdering.violations([.textDelta("x"), .done(.stop)]).isEmpty, "usage missing")
        #expect(!EventOrdering.violations([.textDelta("x"), .done(.stop), Self.u]).isEmpty, "usage after done")
        #expect(!EventOrdering.violations([Self.u, Self.u, .done(.stop)]).isEmpty, "two usages")
        #expect(!EventOrdering.violations([.toolCallDone(id: "c", name: "f", argsJSON: "{}"), Self.u, .done(.toolCalls)]).isEmpty,
                "done without delta")
        #expect(!EventOrdering.violations([.toolCallDelta(id: "c", name: nil, argsFragment: "{}"),
                                           .toolCallDone(id: "c", name: "f", argsJSON: "{}"), Self.u, .done(.toolCalls)]).isEmpty,
                "first delta without name")
        #expect(!EventOrdering.violations([.toolCallDelta(id: "c", name: "f", argsFragment: "{}"),
                                           .toolCallDone(id: "c", name: "f", argsJSON: "{}"),
                                           .toolCallDelta(id: "c", name: nil, argsFragment: " "), Self.u, .done(.toolCalls)]).isEmpty,
                "delta after done")
        #expect(!EventOrdering.violations([.toolCallDelta(id: "c", name: "f", argsFragment: "{}"),
                                           .toolCallDone(id: "c", name: "g", argsJSON: "{}"), Self.u, .done(.toolCalls)]).isEmpty,
                "name mismatch")
        #expect(!EventOrdering.violations([.textDelta("x"), Self.u, .done(.toolCalls)]).isEmpty, "toolCalls without call")
        #expect(!EventOrdering.violations([.toolCallDelta(id: "c", name: "f", argsFragment: "{"), Self.u, .done(.stop)]).isEmpty,
                "unfinished call")
    }

    static let scriptsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/fixtures/scripts")

    /// Recorded traces: every committed ScriptedEngine script (each turn segment) conforms.
    @Test func everyCommittedScriptConforms() async throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.scriptsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        #expect(files.count >= 8)
        for f in files {
            let script = try EngineScript(contentsOf: f)
            if script.segments.joined().contains(where: { if case .crash = $0.kind { true } else { false } }) { continue }
            let player = EngineScriptPlayer(script: script, sleep: { _ in await Task.yield() })
            for seg in 0..<script.segments.count {
                // Segment k plays for a prompt with k assistant messages.
                var msgs = [ChatMessage(role: .user, content: "q")]
                for _ in 0..<seg { msgs += [ChatMessage(role: .assistant, content: "a"), ChatMessage(role: .user, content: "q")] }
                let req = ChatRequest(modelSlot: .scripted(f.path), messages: msgs)
                let box = Mutex<[EngineEvent]>([])
                await player.play(req) { out in if case .engine(let e) = out { box.withLock { $0.append(e) } } }
                let events = box.withLock { $0 }
                let v = EventOrdering.violations(events)
                #expect(v.isEmpty, "\(f.lastPathComponent) segment \(seg): \(v)")
            }
        }
    }

    /// R-229 AC2: every request field survives the wire.
    @Test func chatRequestCarriesEveryContractField() throws {
        let tools = [ToolSchema(name: "get_time", description: "Current time", parametersJSON: #"{"type":"object","properties":{"tz":{"type":"string"}},"required":["tz"]}"#)]
        let req = ChatRequest(
            requestID: UUID(), sessionID: UUID(), modelSlot: ModelSlot(engine: .mlx, key: "chat-9b-q4", path: "/m", footprintBytes: 9, vision: true, contextTokens: 16384),
            messages: [.layer(PromptLayer(id: "base", content: "sys")), .message(ChatMessage(role: .user, content: "hi", imagePaths: ["/a.png"])),
                       .message(ChatMessage(role: .tool, content: "12:00", toolCallID: "call_1"))],
            tools: tools, toolChoice: .function("get_time"), reasoning: ReasoningOptions(on: true, budget: 512),
            sampling: Sampling(temperature: 0.2, topP: 0.9, topK: 20, maxTokens: 77, seed: 42),
            images: [URL(fileURLWithPath: "/b.jpg")], grammar: "root ::= \"x\"")
        let back = try JSONDecoder().decode(ChatRequest.self, from: JSONEncoder().encode(req))
        #expect(back == req)
        #expect(back.requestID == req.requestID)  // the cancel token (Cancel{requestID})
        #expect(back.tools == tools && back.toolChoice == .function("get_time"))
        #expect(back.reasoning.on && back.reasoning.budget == 512)
        #expect(back.sampling.seed == 42 && back.sampling.maxTokens == 77 && back.sampling.topK == 20)
        #expect(back.images.map(\.path) == ["/b.jpg"])
        for c in [ToolChoice.auto, .none, .required] {
            #expect(try JSONDecoder().decode(ToolChoice.self, from: JSONEncoder().encode(c)) == c)
        }
        let cancel = Cancel(requestID: req.requestID)
        #expect(try JSONDecoder().decode(Cancel.self, from: JSONEncoder().encode(cancel)).requestID == req.requestID)
    }

    /// The M1.T13 Usage trace fields are optional on the wire (older payloads decode; new ones round-trip).
    @Test func usageTraceFieldsRoundTrip() throws {
        var u = Usage(promptTokens: 1, completionTokens: 2)
        u.toolCallsConstrained = 2
        u.toolCallsRejected = 0
        u.rawToolSyntaxScrubbed = 1
        #expect(try JSONDecoder().decode(Usage.self, from: JSONEncoder().encode(u)) == u)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Usage(promptTokens: 1, completionTokens: 2))) as! [String: Any]
        old.removeValue(forKey: "toolCallsConstrained")
        let d = try JSONDecoder().decode(Usage.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(d.toolCallsConstrained == nil)
    }
}
