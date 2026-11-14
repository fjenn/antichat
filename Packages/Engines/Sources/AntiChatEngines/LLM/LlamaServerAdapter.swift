// LlamaServerAdapter (M0.T04 step 5, M1.T12): GGUF chat through a supervised single-model llama-server over its
// unix socket (LlamaServerSupervisor, A-M1-T12a). Streams `POST /v1/chat/completions` (`stream: true`) and parses
// the SSE body with EventSource 1.5.1 (`AsyncSequence<UInt8>.events`, P-shell-09). Cancel = drop the stream =
// connection cancel (HTTP abort). When the server dies mid-stream (crash, OOM, `kill -9`) the stream ends with
// the error its stderr fault maps to (LlamaFaultClassifier: model.notEnoughMemory, model.corrupt, else
// engine.restarted) and the next request respawns it (the scheduler sees `isAlive == false`).
import AntiChatEngineProtocol
import AntiChatFoundation
import EventSource
import Foundation

public actor LlamaServerAdapter: EngineAdapter {
    public nonisolated let kind = EngineKind.llama
    private var supervisor: LlamaServerSupervisor?
    private var loaded: (key: String, model: String, ctx: Int?)?
    private let binary: String
    private let kvDir: String
    private let logFile: String?
    private let watchdogExecutable: String?
    /// M1.T14 step 4 + M1.T20: the chat → slot assignment of the running server (`total_slots` from `GET /props`),
    /// so a chat's next turn lands on the slot whose KV already holds its prefix (`cache_prompt: true`), with KV
    /// save/restore under `kvDir` for non-incognito chats (`LlamaSlotTable`). nil = the server did not say.
    private var slotTable: LlamaSlotTable?
    /// The model tag in saved KV file names (a file only ever restores into the model that wrote it).
    private var modelTag = ""
    /// Saved KV files kept per model (oldest removed first).
    static let maxSavedSlots = 8

    public init(binary: String, kvDir: String, logFile: String?, watchdogExecutable: String?) {
        self.binary = binary
        self.kvDir = kvDir
        self.logFile = logFile
        self.watchdogExecutable = watchdogExecutable
    }

    /// The llama-server pid (0 = none).
    public var serverPID: pid_t {
        get async { await supervisor?.pid ?? 0 }
    }

    /// The running server's argument vector (LlamaRouterControl rule check).
    public var lastArgs: [String] {
        get async { await supervisor?.lastArgs ?? [] }
    }

    public var watchdogPID: pid_t {
        get async { await supervisor?.watchdogPID ?? 0 }
    }

    /// The resident server is still running (false after a crash: the next load respawns it).
    public var isAlive: Bool {
        get async {
            guard let supervisor else { return false }
            return await supervisor.isRunning
        }
    }

    /// The weights and optional vision projector for a slot: a `.gguf` file, or a directory holding one
    /// model `.gguf` plus `*mmproj*.gguf` (M0.T09 evil-9b layout).
    static func files(for slot: ModelSlot) throws -> (model: String, mmproj: String?) {
        let url = URL(fileURLWithPath: slot.path)
        if url.pathExtension == "gguf" { return (url.path, nil) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".gguf") }.sorted()
        let mmproj = names.first { $0.lowercased().contains("mmproj") }
        guard let model = names.first(where: { !$0.lowercased().contains("mmproj") }) else {
            throw AntiChatError(.modelMissing, detail: "no .gguf in \(url.lastPathComponent)")
        }
        return (url.appendingPathComponent(model).path, mmproj.map { url.appendingPathComponent($0).path })
    }

    @discardableResult
    public func load(_ slot: ModelSlot) async throws -> Double {
        let (model, mmproj) = try Self.files(for: slot)
        if let l = loaded, l.model == model, l.ctx == slot.contextTokens, await isAlive {
            loaded = (slot.key, model, slot.contextTokens)
            return 0
        }
        await stop()
        var cfg = LlamaServerSupervisor.Config(
            binary: binary, model: model, mmproj: slot.vision ? mmproj : nil, logFile: logFile,
            watchdogExecutable: watchdogExecutable)
        cfg.ctxSize = slot.contextTokens ?? LlamaRouterControl.defaultContext
        // M1.T20: `--slot-save-path` for the non-incognito slot save/restore (incognito sessions never use it).
        let persistence = !kvDir.isEmpty
            && (try? FileManager.default.createDirectory(atPath: kvDir, withIntermediateDirectories: true)) != nil
        if persistence { cfg.slotSavePath = kvDir }
        let sup = LlamaServerSupervisor(config: cfg)
        supervisor = sup
        let t = try await sup.start()
        loaded = (slot.key, model, slot.contextTokens)
        modelTag = "\(slot.key)-\(slot.contextTokens ?? 0)"
        slotTable = await Self.totalSlots(sup.client).map { LlamaSlotTable(slots: $0, persistence: persistence) }
        Self.pruneSavedSlots(in: kvDir, keep: Self.maxSavedSlots)
        return t
    }

    /// Removes saved KV files beyond the newest `keep` (by modification date).
    static func pruneSavedSlots(in dir: String, keep: Int) {
        guard !dir.isEmpty else { return }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let bins = files.filter { $0.pathExtension == "bin" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for f in bins.dropFirst(keep) { try? fm.removeItem(at: f) }
    }

    public var loadedKey: String? { loaded?.key }

    public func unload() async { await stop() }

    /// `GET /props` → `total_slots` (llama.cpp tools/server @620d222); nil when the server does not say.
    static func totalSlots(_ client: UnixHTTPClient) async -> Int? {
        guard let r = try? await client.get("/props"), r.status == 200, let d = try? await r.data(),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return obj["total_slots"] as? Int
    }

    /// The slot for a request: its chat's own slot while it has one, else the least recently used slot, after
    /// saving the evicted chat's KV and restoring this chat's saved KV (never for incognito sessions, M1.T20).
    func slot(for request: ChatRequest, client: UnixHTTPClient) async -> Int? {
        guard var table = slotTable, table.slots > 0 else { return nil }
        let (s, actions) = table.assign(request.sessionID, incognito: request.incognito)
        slotTable = table
        for action in actions {
            switch action {
            case .save(let slot, let session):
                let ok = await Self.slotAction(client, slot: slot, action: "save",
                                               file: LlamaSlotTable.fileName(session: session, modelTag: modelTag))
                if !ok { slotTable?.saveFailed(session) }
                Self.pruneSavedSlots(in: kvDir, keep: Self.maxSavedSlots)
            case .restore(let slot, let session):
                _ = await Self.slotAction(client, slot: slot, action: "restore",
                                          file: LlamaSlotTable.fileName(session: session, modelTag: modelTag))
            }
        }
        return s
    }

    /// `POST /slots/{id}?action=save|restore {"filename"}` (llama.cpp tools/server, needs `--slot-save-path`).
    static func slotAction(_ client: UnixHTTPClient, slot: Int, action: String, file: String) async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: ["filename": file]),
              let r = try? await client.post("/slots/\(slot)?action=\(action)", json: body)
        else { return false }
        _ = try? await r.data()
        return r.status == 200
    }

    public func stop() async {
        await supervisor?.stop()
        supervisor = nil
        loaded = nil
    }

    /// OpenAI chat message. Images (local paths only, architecture §4.3) become `image_url` data-URI parts,
    /// which llama-server feeds to the mmproj (M0.T09 step 4).
    static func openAIMessage(_ m: ChatMessage) -> [String: Any] {
        // M1.T16: tool-loop history in the OpenAI shape (`tool_calls` on the assistant step, `tool_call_id` on results).
        if m.role == .assistant, !m.toolCalls.isEmpty {
            return ["role": "assistant", "content": m.content, "tool_calls": m.toolCalls.map { c in
                ["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.argumentsJSON]] as [String: Any]
            }]
        }
        if m.role == .tool {
            var out: [String: Any] = ["role": "tool", "content": m.content]
            if let id = m.toolCallID { out["tool_call_id"] = id }
            if let n = m.toolName { out["name"] = n }
            return out
        }
        guard !m.imagePaths.isEmpty else { return ["role": m.role.rawValue, "content": m.content] }
        AppLog.log(.engine, .info, "vision_parts=\(m.imagePaths.count) (llama-server)")  // M6.T05 (AT-021 check 1)
        var parts: [[String: Any]] = []
        for p in m.imagePaths {
            guard let d = FileManager.default.contents(atPath: p) else { continue }
            let ext = URL(fileURLWithPath: p).pathExtension.lowercased()
            let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/\(ext.isEmpty ? "png" : ext)"
            parts.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(d.base64EncodedString())"]])
        }
        parts.append(["type": "text", "text": m.content])
        return ["role": m.role.rawValue, "content": parts]
    }

    /// The error for a stream that broke: the server's classified fault when it died, else the transport error.
    /// nil = the server was being stopped on purpose (swap, unload): the stream ends as cancelled, never as a failure,
    /// whatever the dying server printed or however it ended (fix/soak-engine).
    static func streamFailure(_ supervisor: LlamaServerSupervisor, transport: String) async -> AntiChatError? {
        if supervisor.isStopping { return nil }
        // A dead server's socket closes before the reaper notices the exit (≤ 50 ms poll): give it a moment.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while supervisor.exit == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return failure(exit: supervisor.exit, isStopping: supervisor.isStopping, transport: transport,
                       fault: { supervisor.failure(context: $0) })
    }

    /// `streamFailure`'s decision, testable without a server: an intentional stop (exit marked `intentional`, or
    /// `stop()` begun) → nil; a died server → its classified fault; else the transport error.
    static func failure(exit: LlamaServerSupervisor.Exit?, isStopping: Bool, transport: String,
                        fault: (String) -> AntiChatError) -> AntiChatError? {
        if isStopping || exit?.intentional == true { return nil }
        if exit != nil { return fault("llama-server died mid-stream (\(transport))") }
        return AntiChatError.engine("llamaStream", transport)
    }

    /// A stream with only the cancelled terminal (a request that met an intentional stop).
    static func cancelledStream() -> AsyncStream<AdapterOutput> {
        AsyncStream { cont in
            cont.event(.done(.cancelled))
            cont.finish()
        }
    }

    /// `tool_choice` + `tools` for llama-server. M2.T22: llama.cpp takes only the strings auto / none / required, so a
    /// forced function (a chip, the fallback re-ask) goes out as `required` over that one tool.
    static func toolFields(_ request: ChatRequest) -> (choice: Any?, tools: [ToolSchema]) {
        if case .function(let name)? = request.toolChoice {
            let only = request.tools.filter { $0.name == name }
            if !only.isEmpty { return ("required", only) }
        }
        return (request.toolChoice?.openAIValue, request.tools)
    }

    /// R2 review P1-2: the prompt-processing progress of one llama-server stream chunk (`return_progress`:
    /// `prompt_progress` = total / cache / processed / time_ms), as the `prefillProgress` fraction of the uncached
    /// prompt (processed − cache) / (total − cache); nil for a chunk without one.
    static func prefillFraction(_ chunk: [String: Any]) -> Double? {
        guard let p = chunk["prompt_progress"] as? [String: Any], let total = (p["total"] as? NSNumber)?.doubleValue,
              let processed = (p["processed"] as? NSNumber)?.doubleValue else { return nil }
        let cache = (p["cache"] as? NSNumber)?.doubleValue ?? 0
        guard total > cache else { return 1 }
        return min(1, max(0, (processed - cache) / (total - cache)))
    }

    public func generate(_ request: ChatRequest, context: GenerationContext) async throws -> AsyncStream<AdapterOutput> {
        guard let supervisor, let model = loaded?.model else { throw AntiChatError.model("notLoaded", request.modelSlot.key) }
        if supervisor.exit != nil { throw supervisor.failure(context: "llama-server not running") }
        var body: [String: Any] = [
            "model": URL(fileURLWithPath: model).lastPathComponent, "stream": true, "max_tokens": request.sampling.maxTokens,
            "temperature": request.sampling.temperature, "top_p": request.sampling.topP,
            "stream_options": ["include_usage": true],
            // R2 review P1-2: prompt processing reports progress (`prompt_progress` chunks, one per batch) instead of
            // sending nothing until the first token, so a long prefill is not silence to the turn's stall watchdog.
            "return_progress": true,
            // M1.T14 step 4: reuse the slot's KV for the common prompt prefix (stable layers + history).
            "cache_prompt": true,
            "chat_template_kwargs": ["enable_thinking": request.reasoning.on],
            "messages": request.flattenedMessages.map(Self.openAIMessage),
        ]
        if request.sampling.topK > 0 { body["top_k"] = request.sampling.topK }
        let (choice, tools) = Self.toolFields(request)
        if let choice { body["tool_choice"] = choice }
        if let seed = request.sampling.seed { body["seed"] = seed }
        if !tools.isEmpty { body["tools"] = tools.map(\.openAIObject) }
        if let g = request.grammar { body["grammar"] = g }
        if let s = await slot(for: request, client: supervisor.client) { body["id_slot"] = s }
        let json = try JSONSerialization.data(withJSONObject: body)
        let response: UnixHTTPResponse
        do {
            response = try await supervisor.client.post("/v1/chat/completions", json: json)
        } catch {
            guard let failure = await Self.streamFailure(supervisor, transport: "\(error)") else { return Self.cancelledStream() }
            throw failure
        }
        guard response.status == 200 else {
            let text = String(decoding: try await response.data(), as: UTF8.self)
            throw AntiChatError.engine("llamaHTTP\(response.status)", String(text.prefix(300)))
        }
        let ctx = context
        return AsyncStream<AdapterOutput>(bufferingPolicy: .unbounded) { cont in
            let task = Task {
                var toolArgs: [Int: (id: String, name: String, args: String)] = [:]
                var finish: FinishReason = .stop
                var firstContent: ContinuousClock.Instant?
                var sawDone = false
                var transportError: String?
                do {
                    for try await event in response.body.events {
                        if Task.isCancelled { break }
                        if event.data == "[DONE]" { sawDone = true; break }
                        guard let d = event.data.data(using: .utf8),
                            let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        // Progress precedes the first token; none is forwarded after content it preceded.
                        if firstContent == nil, let f = Self.prefillFraction(obj) {
                            cont.yield(.lifecycle(.prefillProgress(f)))
                        }
                        if let choices = obj["choices"] as? [[String: Any]], let c = choices.first {
                            if let r = c["finish_reason"] as? String {
                                finish = r == "length" ? .length : r == "tool_calls" ? .toolCalls : .stop
                            }
                            if let delta = c["delta"] as? [String: Any] {
                                if let s = delta["reasoning_content"] as? String, !s.isEmpty {
                                    if firstContent == nil { firstContent = .now }
                                    cont.event(.reasoningDelta(s))
                                }
                                if let s = delta["content"] as? String, !s.isEmpty {
                                    if firstContent == nil { firstContent = .now }
                                    cont.event(.textDelta(s))
                                }
                                if let calls = delta["tool_calls"] as? [[String: Any]] {
                                    for call in calls {
                                        if firstContent == nil { firstContent = .now }
                                        let idx = call["index"] as? Int ?? 0
                                        let fn = call["function"] as? [String: Any]
                                        let isNew = toolArgs[idx] == nil
                                        var cur = toolArgs[idx] ?? (call["id"] as? String ?? "call_\(idx)", fn?["name"] as? String ?? "", "")
                                        let frag = fn?["arguments"] as? String ?? ""
                                        cur.args += frag
                                        toolArgs[idx] = cur
                                        cont.event(.toolCallDelta(id: cur.id, name: isNew ? cur.name : nil, argsFragment: frag))
                                    }
                                }
                            }
                        }
                        if let t = obj["timings"] as? [String: Any] {
                            let promptN = t["prompt_n"] as? Int ?? 0
                            let cacheN = t["cache_n"] as? Int ?? 0
                            let predN = t["predicted_n"] as? Int ?? 0
                            let promptMS = t["prompt_ms"] as? Double ?? 0
                            let predMS = t["predicted_ms"] as? Double ?? 0
                            let ttft = firstContent.map { EngineTime.ms($0 - ctx.receivedAt) } ?? 0
                            cont.event(
                                .usage(
                                    Usage(
                                        promptTokens: promptN + cacheN, completionTokens: predN, cachedTokens: cacheN,
                                        ttftMs: ttft, promptTime: promptMS / 1000, generateTime: predMS / 1000,
                                        loadTime: ctx.loadTime)))
                        }
                    }
                } catch {
                    transportError = "\(error)"
                }
                if Task.isCancelled {
                    cont.event(.done(.cancelled))
                    cont.finish()
                    return
                }
                // A body that ended without `[DONE]` means the connection broke: usually a dead server.
                if transportError != nil || !sawDone {
                    if let failure = await Self.streamFailure(supervisor, transport: transportError ?? "stream ended without [DONE]") {
                        cont.event(.error(failure))
                    } else {
                        cont.event(.done(.cancelled))  // the server was stopped on purpose: no failure to report
                    }
                    cont.finish()
                    return
                }
                for (_, v) in toolArgs.sorted(by: { $0.key < $1.key }) {
                    cont.event(.toolCallDone(id: v.id, name: v.name, argsJSON: v.args))
                }
                if !toolArgs.isEmpty, finish == .stop { finish = .toolCalls }
                cont.event(.done(finish))
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
