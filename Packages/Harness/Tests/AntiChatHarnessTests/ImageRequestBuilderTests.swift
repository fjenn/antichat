// AT-286 AC3 + step 2 (R-286; M4.T06): tool arguments + model profile → the sd-server request. negative_prompt only for
// a model that uses one; resolution per aspect × speed class at equal pixel count (multiples of 64); the seed is the
// call's or a recorded random one; style joins the prompt; img-edit adds `qwen_image_zero_cond_t=true` (A-M4-04).
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct ImageRequestBuilderTests {
    static let klein = ImageModelSet(key: "img-klein-q4", diffusionModel: "d", llm: "t", vae: "v", footprintBytes: 1)

    @Test func testNegativePromptPerCatalog() throws {
        let call = try ImageRequestBuilder.parse(#"{"prompt":"a fox","negative_prompt":"blur"}"#, tool: "create_image")
        #expect(ImageRequestBuilder.request(call, model: Self.klein, speed: .s1).negativePrompt == nil, "klein: omitted")
        let zit = ImageModelSet(key: "img-zit-q8", diffusionModel: "d", llm: "t", vae: "v", footprintBytes: 1)
        #expect(ImageRequestBuilder.request(call, model: zit, speed: .s4).negativePrompt == nil, "Z-Image-Turbo: omitted")
        let uses = ImageModelProfile(usesNegativePrompt: true, steps: 20, cfg: 5)
        #expect(ImageRequestBuilder.request(call, model: Self.klein, speed: .s1, profile: uses).negativePrompt == "blur", "included when used")
        for key in ["img-klein-q4", "img-klein-q8", "img-zit-q8", "img-edit-q4", "img-edit-q8"] {
            #expect(!ImageModelProfile.forKey(key).usesNegativePrompt, "\(key)")
        }
    }

    @Test func resolutionTable() {
        let s12: [String: (Int, Int)] = ["1:1": (768, 768), "3:2": (960, 640), "2:3": (640, 960), "16:9": (1024, 576), "9:16": (576, 1024)]
        let s34: [String: (Int, Int)] = ["1:1": (1024, 1024), "3:2": (1280, 832), "2:3": (832, 1280), "16:9": (1344, 768), "9:16": (768, 1344)]
        for (a, want) in s12 {
            for s in [ImageSpeedClass.s1, .s2] { let r = ImageRequestBuilder.resolution(aspect: a, speed: s); #expect(r == want, "\(a) \(s)") }
        }
        for (a, want) in s34 {
            for s in [ImageSpeedClass.s3, .s4] { let r = ImageRequestBuilder.resolution(aspect: a, speed: s); #expect(r == want, "\(a) \(s)") }
        }
        for a in s12.keys {
            let (w, h) = ImageRequestBuilder.resolution(aspect: a, speed: .s3)
            #expect(w % 64 == 0 && h % 64 == 0 && abs(Double(w * h) / (1024 * 1024) - 1) < 0.1)
        }
    }

    @Test func seedRecordedStyleAndEditArgs() throws {
        let fixed = try ImageRequestBuilder.parse(#"{"prompt":"a fox","seed":7,"style":"watercolor"}"#, tool: "create_image")
        let r = ImageRequestBuilder.request(fixed, model: Self.klein, speed: .s1)
        #expect(r.seed == 7 && r.prompt == "a fox, watercolor" && r.steps == 4 && r.cfgScale == 1 && r.preview == "proj")
        let random = try ImageRequestBuilder.parse(#"{"prompt":"a fox"}"#, tool: "create_image")
        #expect(ImageRequestBuilder.request(random, model: Self.klein, speed: .s1, randomSeed: { 99 }).seed == 99)
        #expect(throws: ImageRequestBuilder.BuildError.self) { try ImageRequestBuilder.parse(#"{"prompt":"x"}"#, tool: "edit_image") }
        #expect(throws: ImageRequestBuilder.BuildError.self) { try ImageRequestBuilder.parse(#"{"prompt":"  "}"#, tool: "create_image") }
        let edit = ImageModelSet(key: "img-edit-q8", diffusionModel: "d", llm: "t", vae: "v", footprintBytes: 1)
        let e = ImageRequestBuilder.request(try ImageRequestBuilder.parse(#"{"prompt":"make it red","source_image_id":"a"}"#, tool: "edit_image"),
                                            model: edit, speed: .s3, initImagePath: "/src.png")
        #expect(e.model.extraArgs == ["--model-args", "qwen_image_zero_cond_t=true"] && e.initImagePath == "/src.png")
        #expect(try ImageRequestBuilder.parse(#"{"prompt":"x","aspect":"7:5"}"#, tool: "create_image").aspect == "1:1")
    }

    /// M4 lead decision (NFR-R1): T0–T2 build `preview: none` (progress only, final image checked after the generator
    /// unloads); T3+ keep live previews.
    @Test func livePreviewsOnlyFromT3() throws {
        let call = try ImageRequestBuilder.parse(#"{"prompt":"a lighthouse"}"#, tool: "create_image")
        for t in [DeviceTier.t0, .t1, .t2] {
            #expect(!ImageTurnPolicy.livePreviews(tier: t))
            #expect(ImageRequestBuilder.request(call, model: Self.klein, speed: .s1, livePreviews: ImageTurnPolicy.livePreviews(tier: t)).preview == "none")
        }
        #expect(ImageTurnPolicy.livePreviews(tier: .t3))
        #expect(ImageRequestBuilder.request(call, model: Self.klein, speed: .s4, livePreviews: true).preview == "proj")
    }
}
