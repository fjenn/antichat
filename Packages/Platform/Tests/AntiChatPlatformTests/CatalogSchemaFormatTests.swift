// M2.T05 AT-NFR-SEC2 (decode half): the catalog decoder accepts only safetensors / GGUF / Core ML / ONNX and refuses
// pickle and Python files. Core ML's own `weights/weight.bin` and declared raw tensor files are not pickle.
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct CatalogSchemaFormatTests {
    /// The valid fixture with one model's format or files replaced.
    func mutated(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: CatalogFixtures.data("catalog-valid.json")) as! [String: Any]
        var models = root["models"] as! [String: Any]
        var m = models["chat-2b"] as! [String: Any]
        edit(&m)
        models["chat-2b"] = m; root["models"] = models
        return try JSONSerialization.data(withJSONObject: root)
    }

    func file(_ path: String) -> [String: Any] {
        ["path": path, "size": 1, "sha256": String(repeating: "c", count: 64), "sources": ["https://huggingface.co/a/b/resolve/\(String(repeating: "d", count: 40))/\(path)"]]
    }

    @Test func validFixtureAndBaselineDecode() throws {
        #expect(try CatalogFixtures.catalog("catalog-valid").models.count > 40)
        let b = try #require(CatalogStore.bundledBaseline())
        // The shipped baseline is signed with production key A and must verify under the pinned release keys, and
        // (being a release artefact) not under the test keys a debug build pins.
        #expect(CatalogVerifier(base64Keys: try CatalogFixtures.releaseKeys()).verify(data: b.data, sig: b.sig))
        #expect(!CatalogVerifier(base64Keys: [PinnedKeys.testKeyA, PinnedKeys.testKeyB]).verify(data: b.data, sig: b.sig))
        #expect(try ModelCatalog.decode(b.data).models["chat-0.8b"]?.format == "mlx-safetensors")
    }

    @Test(arguments: ["pytorch_model.bin", "model.pt", "weights.pth", "data.pkl", "modeling_qwen.py", "model.ckpt"])
    func pickleOrCodeRejected(path: String) throws {
        let data = try mutated { m in m["files"] = [file("model.safetensors"), file(path)] }
        #expect(throws: CatalogSchemaError.forbiddenFile(model: "chat-2b", path: path)) { try ModelCatalog.decode(data) }
    }

    @Test func otherFormatRejected() throws {
        let data = try mutated { m in m["format"] = "pytorch" }
        #expect(throws: CatalogSchemaError.forbiddenFormat(model: "chat-2b", format: "pytorch")) { try ModelCatalog.decode(data) }
    }

    @Test func coreMLBundlesAreNotPickle() throws {
        #expect(!CatalogModel.forbiddenFile("Encoder.mlmodelc/weights/weight.bin"))
        #expect(!CatalogModel.forbiddenFile("LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin"))
        #expect(!CatalogModel.forbiddenFile("ANE/af_heart.bin", rawTensors: ["ANE/*.bin"]))
        #expect(CatalogModel.forbiddenFile("ANE/af_heart.bin"))
        let tts = try #require(try CatalogFixtures.catalog("catalog-valid").models["tts"])
        #expect(tts.files.contains { $0.path.hasSuffix(".bin") })
    }

    @Test func schemaOneRejected() throws {
        var root = try JSONSerialization.jsonObject(with: CatalogFixtures.data("catalog-valid.json")) as! [String: Any]
        root["schema"] = 1
        #expect(throws: CatalogSchemaError.unsupportedSchema(1)) { try ModelCatalog.decode(JSONSerialization.data(withJSONObject: root)) }
    }
}
