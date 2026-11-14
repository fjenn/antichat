// M5.T10 step 4 (R-040 AC1, R-043): the `create_video` schema — prompt, negative_prompt?, length short|medium,
// shape square|portrait|landscape, sound Bool, seed?, source_image_id? — and the parser's validation (the harness's
// RepairRetry turns a thrown error into the one repair turn, G-012).
//   make test-unit FILTER=CreateVideoToolSchemaTests
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct CreateVideoToolSchemaTests {
    @Test func schemaHasItsFields() throws {
        let (p, req) = try CreateImageToolSchemaTests.properties(CreateVideoTool.parametersJSON)
        #expect(Set(p.keys) == ["prompt", "negative_prompt", "length", "shape", "sound", "seed", "source_image_id"])
        #expect(req == ["prompt"])
        #expect(p["length"]?["enum"] as? [String] == ["short", "medium"] && p["length"]?["default"] as? String == "short")
        #expect(p["shape"]?["enum"] as? [String] == ["square", "portrait", "landscape"])
        #expect(p["sound"]?["type"] as? String == "boolean" && p["seed"]?["type"] as? String == "integer")
        #expect(p["source_image_id"]?["type"] as? String == "string" && p["prompt"]?["type"] as? String == "string")
        #expect(CreateVideoTool.name == "create_video")
        #expect(CreateVideoTool.lengths == ["short", "medium"] && CreateVideoTool.shapes == ["square", "portrait", "landscape"])
    }

    @Test func parsesAFullCall() throws {
        let c = try CreateVideoTool.parse(#"{"prompt":" waves at dusk ","negative_prompt":"text","length":"medium","shape":"portrait","sound":true,"seed":42,"source_image_id":"art-1","extra":1}"#)
        #expect(c == CreateVideoTool.Call(prompt: "waves at dusk", negativePrompt: "text", length: "medium", shape: "portrait",
                                          sound: true, seed: 42, sourceImageID: "art-1"))
        let min = try CreateVideoTool.parse(#"{"prompt":"a koala"}"#)
        #expect(min == CreateVideoTool.Call(prompt: "a koala"), "unnamed picks stay nil: the card starts from the tier default")
    }

    @Test func rejectsBadArguments() {
        for bad in [#"[]"#, #"{}"#, #"{"prompt":"  "}"#, #"{"prompt":"x","length":"long"}"#, #"{"prompt":"x","shape":"wide"}"#,
                    #"{"prompt":"x","sound":"yes"}"#, #"{"prompt":"x","sound":1}"#, #"{"prompt":"x","seed":-1}"#,
                    #"{"prompt":"x","seed":1.5}"#, #"{"prompt":"x","seed":true}"#, #"{"prompt":"x","source_image_id":3}"#,
                    #"{"prompt":"x","negative_prompt":false}"#] {
            #expect(throws: CreateVideoTool.ParseError.self, "\(bad)") { try CreateVideoTool.parse(bad) }
        }
    }
}
