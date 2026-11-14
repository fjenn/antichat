// M2.T22 (R-235 AC1): a forced function (chip / fallback re-ask) reaches llama-server as `tool_choice: "required"`
// over that one tool (llama.cpp accepts only auto / none / required); other choices pass through.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct LlamaToolChoiceTests {
    /// R2 review P1-2: a `return_progress` chunk (llama.cpp `prompt_progress`) → the uncached prompt's fraction.
    @Test func promptProgressChunkBecomesThePrefillFraction() throws {
        func chunk(_ json: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let mid = try chunk(#"{"choices":[{"delta":{"role":"assistant","content":null},"index":0,"finish_reason":null}],"object":"chat.completion.chunk","prompt_progress":{"total":4096,"cache":1024,"processed":2560,"time_ms":900}}"#)
        #expect(LlamaServerAdapter.prefillFraction(mid) == 0.5)
        let start = try chunk(#"{"prompt_progress":{"total":4096,"cache":1024,"processed":1024,"time_ms":0}}"#)
        #expect(LlamaServerAdapter.prefillFraction(start) == 0)
        let allCached = try chunk(#"{"prompt_progress":{"total":10,"cache":10,"processed":10,"time_ms":0}}"#)
        #expect(LlamaServerAdapter.prefillFraction(allCached) == 1)
        let content = try chunk(#"{"choices":[{"delta":{"content":"Hi"},"index":0}]}"#)
        #expect(LlamaServerAdapter.prefillFraction(content) == nil)
    }

    @Test func forcedFunctionBecomesRequiredOverOneTool() {
        let tools = ["create_image", "web_search", "get_time"].map { ToolSchema(name: $0, description: "", parametersJSON: "{}") }
        var r = ChatRequest(modelSlot: ModelSlot(engine: .llama, key: "k", path: "/x"), messages: [ChatMessage(role: .user, content: "hi")])
        r.tools = tools
        r.toolChoice = .function("create_image")
        let f = LlamaServerAdapter.toolFields(r)
        #expect(f.choice as? String == "required" && f.tools.map(\.name) == ["create_image"])
        r.toolChoice = .auto
        let a = LlamaServerAdapter.toolFields(r)
        #expect(a.choice as? String == "auto" && a.tools.count == 3)
    }
}
