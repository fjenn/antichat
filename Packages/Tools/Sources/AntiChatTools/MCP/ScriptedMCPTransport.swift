// M7.T06 (AT-081, journey 12; DEBUG only): an in-process MCP server that answers from a recorded session,
// `fixtures/web/mcp/scripted-server.jsonl`. One JSON object per line:
//   {"method":"initialize","result":{…}}                       the initialize answer
//   {"method":"tools/list","result":{"tools":[…]}}             the tool list (the last such line wins)
//   {"method":"tools/call","tool":"<name>","result":{…}}       a call's answer (per tool name)
//   {"method":"tools/list","afterCalls":N,"result":{…}}        after the Nth tools/call the server switches to this
//                                                              list and announces list_changed (a rug pull, AT-260 UI)
// Requests without a matching line get JSON-RPC error -32601. Tests and `-ScriptedMCP <file>` use it: no network,
// so no `.mcp` request is ever made. `replaceTools` + list_changed simulate a server changing its tools (M7.T08).
#if DEBUG || ANTICHAT_PERF_HARNESS
import Foundation
import Logging
import MCP

public actor ScriptedMCPTransport: Transport {
    public nonisolated let logger = Logging.Logger(label: "app.antichat.mcp.scripted", factory: { _ in SwiftLogNoOpLogHandler() })
    private var initialize: [String: Any] = [:]
    private var toolList: [[String: Any]] = []
    private var callResults: [String: [String: Any]] = [:]
    /// A later tool list and the number of tools/call requests after which the server switches to it.
    private var laterTools: (afterCalls: Int, tools: [[String: Any]])?
    /// Every request the "server" received: (method, tool name for tools/call, arguments JSON).
    public private(set) var received: [(method: String, tool: String?, arguments: String?)] = []
    private let stream: AsyncThrowingStream<Data, any Swift.Error>
    private let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation

    public init(jsonl: String) {
        (stream, continuation) = AsyncThrowingStream.makeStream()
        for line in jsonl.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = o["method"] as? String, let result = o["result"] as? [String: Any] else { continue }
            switch method {
            case "initialize": initialize = result
            case "tools/list" where o["afterCalls"] != nil:
                laterTools = ((o["afterCalls"] as? Int) ?? 1, result["tools"] as? [[String: Any]] ?? [])
            case "tools/list": toolList = result["tools"] as? [[String: Any]] ?? []
            case "tools/call": if let t = o["tool"] as? String { callResults[t] = result }
            default: break
            }
        }
    }

    public init(contentsOf url: URL) throws { self.init(jsonl: try String(contentsOf: url, encoding: .utf8)) }

    public func connect() async throws {}
    public func disconnect() async {}
    public func receive() -> AsyncThrowingStream<Data, any Swift.Error> { stream }

    public func send(_ data: Data) async throws {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let method = o["method"] as? String else { return }
        let params = o["params"] as? [String: Any]
        let tool = params?["name"] as? String
        let args = (params?["arguments"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) }
        received.append((method, tool, args))
        guard let id = o["id"] else { return }  // a notification
        var result: [String: Any]?
        switch method {
        case "initialize": result = initialize
        case "tools/list": result = ["tools": toolList]
        case "tools/call": result = tool.flatMap { callResults[$0] }
        case "ping": result = [:]
        default: result = nil
        }
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { reply["result"] = result } else { reply["error"] = ["code": -32601, "message": "not scripted: \(method)"] }
        continuation.yield(try JSONSerialization.data(withJSONObject: reply))
        if method == "tools/call", let later = laterTools, calls(of: nil) >= later.afterCalls {
            laterTools = nil
            toolList = later.tools
            let n: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/tools/list_changed"]
            continuation.yield(try JSONSerialization.data(withJSONObject: n))
        }
    }

    /// The server changes its tools (e.g. a description) and announces it (`notifications/tools/list_changed`).
    /// `toolsJSON` = a JSON array of tool objects.
    public func replaceTools(json toolsJSON: String, announce: Bool = true) throws {
        toolList = (try JSONSerialization.jsonObject(with: Data(toolsJSON.utf8))) as? [[String: Any]] ?? []
        guard announce else { return }
        let n: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/tools/list_changed"]
        continuation.yield(try JSONSerialization.data(withJSONObject: n))
    }

    /// The current tool list as JSON.
    public var toolsJSON: String {
        (try? JSONSerialization.data(withJSONObject: toolList, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
    /// tools/call requests received (of `tool`, or of any tool when nil).
    public func calls(of tool: String?) -> Int { received.filter { $0.method == "tools/call" && (tool == nil || $0.tool == tool) }.count }
}
#endif
