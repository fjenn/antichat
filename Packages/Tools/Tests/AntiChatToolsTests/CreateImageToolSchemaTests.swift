// AT-286 AC1 schema leg (R-286; M4.T06 step 1): the image tool schemas carry all nine fields — prompt, negative_prompt,
// aspect, count, style, seed, source_image_id, mode (create_image) and mask_id (edit_image) — with the enums of the spec.
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct CreateImageToolSchemaTests {
    static func properties(_ json: String) throws -> ([String: [String: Any]], [String]) {
        let o = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return (try #require(o["properties"] as? [String: [String: Any]]), o["required"] as? [String] ?? [])
    }

    @Test func createImageHasItsFields() throws {
        let (p, req) = try Self.properties(CreateImageTool.parametersJSON)
        #expect(Set(p.keys) == ["prompt", "negative_prompt", "aspect", "count", "style", "seed", "mode", "source_image_id"])
        #expect(req == ["prompt"])
        #expect(p["aspect"]?["enum"] as? [String] == ["1:1", "3:2", "2:3", "16:9", "9:16"] && p["aspect"]?["default"] as? String == "1:1")
        #expect(p["count"]?["minimum"] as? Int == 1 && p["count"]?["maximum"] as? Int == 8 && p["count"]?["default"] as? Int == 1)
        #expect(p["mode"]?["enum"] as? [String] == ["generate", "variations", "upscale"])
    }

    @Test func editImageHasItsFields() throws {
        let (p, req) = try Self.properties(EditImageTool.parametersJSON)
        #expect(Set(p.keys) == ["prompt", "negative_prompt", "source_image_id", "mask_id", "aspect", "seed", "mode"])
        #expect(Set(req) == ["prompt", "source_image_id"])
        #expect(p["mode"]?["enum"] as? [String] == ["edit", "inpaint", "outpaint"])
        let all = Set(try Self.properties(CreateImageTool.parametersJSON).0.keys).union(p.keys)
        #expect(all.count == 9, "nine fields across the two tools: \(all.sorted())")
    }
}
