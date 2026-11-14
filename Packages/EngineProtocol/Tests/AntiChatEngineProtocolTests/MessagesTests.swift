import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngineProtocol

@Suite struct MessagesTests {
    static func roundTrip<T: Codable>(_ v: T) throws -> (Data, Data) {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let d = try enc.encode(v)
        return (d, try enc.encode(JSONDecoder().decode(T.self, from: d)))
    }

    @Test func clientMessagesRoundTrip() throws {
        let req = ChatRequest(
            modelSlot: ModelSlot(engine: .mlx, key: "chat-0.8b", path: "/m", footprintBytes: 7, vision: true),
            messages: [
                .layer(PromptLayer(id: "base", content: "You are AntiChat.")),
                .message(ChatMessage(role: .user, content: "u", imagePaths: ["/i.png"])),
                .message(ChatMessage(role: .tool, content: "{}", toolCallID: "call_1")),
            ],
            tools: [ToolSchema(name: "echo", description: "Echo")], toolChoice: .function("echo"),
            reasoning: ReasoningOptions(on: true, budget: 512), sampling: Sampling(temperature: 0.1, topP: 0.9, topK: 20, maxTokens: 3, seed: 4),
            images: [URL(fileURLWithPath: "/tmp/a.png")], grammar: "root ::= \"x\"")
        let msgs: [ClientMessage] = [
            .hello(Hello(appBuild: "b")), .chat(req), .cancel(Cancel(requestID: req.requestID)),
            .warmup(Warmup(modelSlot: req.modelSlot)), .evict(Evict(key: "k")), .setPolicy(SetPolicy(budgetB: 9, batch: .fallback)),
            .probe(requestID: UUID()),
        ]
        for m in msgs {
            let (a, b) = try Self.roundTrip(m)
            #expect(a == b)
        }
    }

    /// M9.T05 (NFR-B5): Hello carries the client's pid by default; an older client's Hello (no field) still decodes.
    @Test func helloCarriesTheClientPID() throws {
        #expect(Hello(appBuild: "b").clientPID == getpid())
        let old = try JSONDecoder().decode(Hello.self, from: Data(#"{"protocolVersion":1,"appBuild":"b"}"#.utf8))
        #expect(old.clientPID == nil && old.appBuild == "b")
    }

    @Test func engineEventIsExactlySevenCases() throws {
        // R-229 AC1: the adapter contract. Adding a case here is a contract change (M1.T13 suite).
        let all: [EngineEvent] = [
            .reasoningDelta("r"), .textDelta("t"), .toolCallDelta(id: "c", name: "n", argsFragment: "{"),
            .toolCallDone(id: "c", name: "n", argsJSON: "{}"), .usage(Usage(promptTokens: 1, completionTokens: 2)),
            .done(.stop), .error(AntiChatError(.engineRestarted)),
        ]
        #expect(Set(all.map { "\($0)".prefix { $0 != "(" } }).count == 7)
        #expect(all.filter(\.isTerminal).count == 2)
        #expect(all.filter(\.isDelta).count == 2)
        for e in all {
            let (a, b) = try Self.roundTrip(e)
            #expect(a == b)
        }
    }

    /// AT-273 round 65 (protocol 11): the generation liveness pulse crosses the wire as a lifecycle item.
    @Test func generatingLifecycleRoundTrips() throws {
        let m = ServerMessage.items(UUID(), [.lifecycle(.generating(tokens: 512))], tokens: 0)
        let back = try JSONDecoder().decode(ServerMessage.self, from: JSONEncoder().encode(m))
        guard case .items(let items, _) = back.body, case .lifecycle(.generating(let n))? = items.first else {
            Issue.record("no generating item"); return
        }
        #expect(n == 512)
    }

    @Test func serverMessageEnvelopeAndHeaderFallback() throws {
        let id = UUID()
        let m = ServerMessage.items(
            id, [.lifecycle(.loadState(.loading)), .engine(.textDelta("hi")), .engine(.done(.stop))], tokens: 2)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ServerMessage.self, from: data)
        #expect(back.requestID == id)
        guard case .items(let items, let tokens) = back.body else { Issue.record("wrong body"); return }
        #expect(tokens == 2)
        #expect(items.last?.isTerminal == true)
        // CR-S-25: a body from a newer/garbled peer still yields its requestID through the header.
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["body"] = ["somethingNew": ["x": 1]]
        let garbled = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ServerMessage.self, from: garbled) }
        #expect(try JSONDecoder().decode(ServerMessageHeader.self, from: garbled).requestID == id)
    }

    @Test func helloAckCarriesCapabilities() throws {
        let ack = HelloAck(capabilities: EngineCapabilities(engines: [.mlx, .scripted], reasoning: false), helperPID: 42, recommendedMaxWorkingSetSize: 1)
        let (a, b) = try Self.roundTrip(ServerMessage(requestID: nil, body: .helloAck(ack)))
        #expect(a == b)
        let rejected = AntiChatError.versionMismatch(helper: 4, app: 3)
        #expect(rejected.is(.engineVersionMismatch))
        #expect(rejected.userMessageKey == "engine.versionMismatch")
    }

    @Test func mediaLanesRoundTrip() throws {
        let set = ImageModelSet(key: "img-klein-q4", diffusionModel: "/d.gguf", llm: "/t.gguf", vae: "/v.safetensors", footprintBytes: 9)
        let req = ImageRequest(model: set, prompt: "a lighthouse", width: 768, height: 768, seed: 1, outputPath: "/tmp/o.png",
                               restoreChat: ModelSlot(engine: .mlx, key: "chat-9b-q4", path: "/m"))
        let (a, b) = try Self.roundTrip(ClientMessage.image(req))
        #expect(a == b)
        let items: [StreamItem] = [
            .media(.imageProgress(ImageProgress(pass: 1, step: 2, totalSteps: 4, previewBytes: 10, previewSHA256: "ab", sdServerPID: 3))),
            .media(.scheduler(SchedulerNote(action: "evicted", model: "chat-9b-q4", seconds: 0.2, detail: ["b": "1"]))),
            .media(.imageResult(ImageResult(status: "completed", path: "/tmp/o.png", width: 768, height: 768, sha256: "cd", bytes: 5, metrics: ["final_s": 3]))),
            .engine(.done(.stop)),
        ]
        let back = try JSONDecoder().decode(ServerMessage.self, from: JSONEncoder().encode(ServerMessage.items(req.requestID, items)))
        guard case .items(let got, _) = back.body else { Issue.record("wrong body"); return }
        #expect(got == items)
    }

    @Test func flattenedMessagesJoinLeadingLayersAndAttachImages() {
        let req = ChatRequest(
            modelSlot: .scripted("/s.jsonl"),
            messages: [
                .layer(PromptLayer(id: "base", content: "A")), .layer(PromptLayer(id: "date", content: "B", stable: false)),
                .message(ChatMessage(role: .user, content: "q1")), .message(ChatMessage(role: .assistant, content: "a1")),
                .layer(PromptLayer(id: "late", content: "C")), .message(ChatMessage(role: .user, content: "q2")),
            ],
            images: [URL(fileURLWithPath: "/x.png")])
        let f = req.flattenedMessages
        #expect(f.map(\.role) == [.system, .user, .assistant, .system, .user])
        #expect(f[0].content == "A\n\nB")
        #expect(f[4].imagePaths == ["/x.png"])
        #expect(f[1].imagePaths.isEmpty)
    }

    @Test func toolSchemaFromOpenAI() {
        let json = #"[{"type":"function","function":{"name":"get_weather","description":"Weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]"#
        let t = ToolSchema.fromOpenAI(json)
        #expect(t.count == 1)
        #expect(t[0].name == "get_weather")
        #expect(t[0].parametersJSON.contains("\"city\""))
        let obj = t[0].openAIObject
        #expect(obj["type"] as? String == "function")
    }

    @Test func protocolVersionIsEight() {
        // 2: M0.T05 voice + M0.T06 image; 3: M0.T07 video; 4: M1.T05 contract; 5: M6.T02 countTokens; 6: M6.T03 prefixPin; 7: M3.T01 voiceService. 8: M4.T04 media jobs.
        #expect(EngineProtocolVersion.current == 11)
        #expect(EngineProtocolVersion.serviceName == "app.antichat.AntiChat.Engine")
    }
}
