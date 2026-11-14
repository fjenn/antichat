// M2.T04 AT-300 (R-300 AC2, NFR-SEC2, R-239 AC1): `catalog-tool lint` fails on a gated default model, a missing
// licence, a non-commercial licence without the flag, a pickle `.bin` and a `.py`; a valid catalog passes.
@testable import catalog_tool
import Foundation
import Testing

enum LintFixture {
    static let commit = String(repeating: "a", count: 40)
    static func file(_ path: String, repo: String = "org/repo") -> FileEntry {
        FileEntry(path: path, size: 10, sha256: String(repeating: "b", count: 64),
                  sources: ["https://huggingface.co/\(repo)/resolve/\(commit)/\(path)"], chunk: nil)
    }
    static func model(family: String = "qwen3.5-9b", files: [String] = ["model.safetensors"], license: String? = "Apache-2.0",
                      noncommercial: Bool = false, format: String = "mlx-safetensors") -> ModelEntry {
        ModelEntry(role: "chat", engine: "mlx-swift-lm", engine_min: nil, format: format, quant: "4bit", context_default: 16384,
                   context_max: 262144, capabilities: [], footprint: Footprint(weights_gb: 1, kv_per_token_kb: 32, overhead_gb: 0.5, active_gb: nil),
                   family: family, chat_template: "qwen3.5", shared_group: nil, requires: nil, raw_tensor_files: nil, supersedes: nil,
                   release_notes: nil, license: license, license_url: license.map { _ in "https://example.org/license" },
                   attribution: "test", modification_notice: "quantized", noncommercial_ok: noncommercial,
                   repo: "org/repo", commit: commit, files: files.map { file($0) })
    }
    static func manifest(_ models: [String: ModelEntry]) -> Manifest {
        let cell = Cell(chat: ChatSlot(normal: ChatPick(model: "chat", ctx: 16384, step_down: nil), normal_reason: nil,
                                       evil: ChatPick(model: "evil", ctx: 16384, step_down: nil), evil_reason: nil,
                                       evil_family_reason: nil, fast_first: "fast"),
                        embed: "embed", embed_reason: nil, rerank: nil, rerank_reason: "needs_ram_24", title: "@chat_fast",
                        csam_check: nil, csam_check_reason: "pending_M4", voice: nil, voice_reason: "test",
                        photo: nil, photo_reason: "test", video: nil, video_reason: "test")
        return Manifest(catalog_version: 1, issued: "2026-11-01T00:00:00Z", expires: "2027-01-30T00:00:00Z", min_app_version: "1.0.0",
                        revoked: [], roles: [], tone_sentence: "x", on_demand: [],
                        assignments: ["T1": ["S1": cell, "S2": cell, "S3": cell, "S4": cell]], models: models)
    }
    static var valid: [String: ModelEntry] {
        ["chat": model(), "evil": model(), "fast": model(family: "qwen3.5-0.8b"), "embed": model(family: "embed")]
    }
    static func gated(_ models: [String: ModelEntry], except: Set<String> = []) -> [String: Bool] {
        models.mapValues { _ in false }.merging(except.map { ($0, true) }) { $1 }
    }
}

@Suite struct CatalogLintTests {
    /// A-M5-11: a commit-pinned GitHub raw URL is a valid source; a branch URL or another host is not.
    @Test func sourcesMustBeCommitPinned() {
        func errors(_ source: String) -> [String] {
            var models = LintFixture.valid
            var chat = LintFixture.model()
            chat.files[0].sources = [source]
            models["chat"] = chat
            return Lint.run(LintFixture.manifest(models), gated: LintFixture.gated(models)).filter { $0.contains("source") }
        }
        #expect(errors("https://raw.githubusercontent.com/madebyollin/taehv/\(LintFixture.commit)/safetensors/taew2_2.safetensors").isEmpty)
        #expect(!errors("https://raw.githubusercontent.com/madebyollin/taehv/main/safetensors/taew2_2.safetensors").isEmpty)
        #expect(!errors("https://huggingface.co/org/repo/resolve/main/model.safetensors").isEmpty)
        #expect(!errors("https://example.org/\(LintFixture.commit)/model.safetensors").isEmpty)
    }

    @Test func validCatalogPasses() {
        let m = LintFixture.manifest(LintFixture.valid)
        #expect(Lint.run(m, gated: LintFixture.gated(m.models)) == [])
    }

    @Test func gatedDefaultModelFails() {
        let m = LintFixture.manifest(LintFixture.valid)
        #expect(Lint.run(m, gated: LintFixture.gated(m.models, except: ["chat"])).contains { $0.contains("chat: gated") })
    }

    @Test func missingLicenseFails() {
        var models = LintFixture.valid
        models["chat"] = LintFixture.model(license: nil)
        let m = LintFixture.manifest(models)
        #expect(Lint.run(m, gated: LintFixture.gated(models)).contains { $0.contains("chat: no license") })
    }

    @Test func nonCommercialWithoutFlagFails() {
        var models = LintFixture.valid
        models["chat"] = LintFixture.model(license: "CC-BY-NC-4.0")
        #expect(Lint.run(LintFixture.manifest(models), gated: LintFixture.gated(models)).contains { $0.contains("non-commercial") })
        models["chat"] = LintFixture.model(license: "CC-BY-NC-4.0", noncommercial: true)
        #expect(Lint.run(LintFixture.manifest(models), gated: LintFixture.gated(models)) == [])
    }

    @Test func pickleBinFails() {
        var models = LintFixture.valid
        models["chat"] = LintFixture.model(files: ["pytorch_model.bin"])
        #expect(Lint.run(LintFixture.manifest(models), gated: LintFixture.gated(models)).contains { $0.contains(".bin") })
    }

    @Test func coreMLWeightsAreNotPickle() {
        #expect(Lint.forbiddenFile("Encoder.mlmodelc/weights/weight.bin") == nil)
        #expect(Lint.forbiddenFile("LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin") == nil)
        #expect(Lint.forbiddenFile("ANE/af_heart.bin", rawTensors: ["ANE/*.bin"]) == nil)
        #expect(Lint.forbiddenFile("ANE/af_heart.bin") == ".bin")
    }

    @Test func remoteCodeFails() {
        var models = LintFixture.valid
        models["embed"] = LintFixture.model(family: "embed", files: ["model.safetensors", "modeling_custom.py"])
        #expect(Lint.run(LintFixture.manifest(models), gated: LintFixture.gated(models)).contains { $0.contains(".py") })
    }

    @Test func otherFormatFails() {
        var models = LintFixture.valid
        models["chat"] = LintFixture.model(format: "pytorch")
        #expect(Lint.run(LintFixture.manifest(models), gated: LintFixture.gated(models)).contains { $0.contains("format pytorch") })
    }

    @Test func evilOutsideNormalFamilyNeedsReason() {
        var models = LintFixture.valid
        models["evil"] = LintFixture.model(family: "llama-8b")
        #expect(Lint.run(LintFixture.manifest(models), gated: LintFixture.gated(models)).contains { $0.contains("R-239") })
    }

    @Test func globStarCrossesDirectories() {
        #expect(globMatch("ANE/*", "ANE/sub/file.bin"))
        #expect(globMatch("*.safetensors", "model-00001-of-00002.safetensors"))
        #expect(!globMatch("*.json", "model.safetensors"))
    }
}
