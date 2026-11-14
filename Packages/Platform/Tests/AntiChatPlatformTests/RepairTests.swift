// AT-NFR-S5 + AT-NFR-SEC2 (load-time half) — M2.T10: a truncated, a deleted and a byte-flipped blob each refuse the load
// with `model.corrupt` and the exact re-download size; Repair re-fetches only those blobs and the view loads again. A
// view naming a pickle / Python file is refused at load whatever the catalog said.
@testable import AntiChatFoundation
@testable import AntiChatPlatform
import AntiChatStorage
import Darwin
import Foundation
import Testing

@Suite(.serialized) struct RepairTests {
    @Test func corruptMissingTruncatedRefusedThenRepaired() async throws {
        let f = try StoreFixture("repair", sizesMB: ["tokenizer.json": 2, "model.safetensors": 6, "config.json": 1, "evil.gguf": 1])
        let dl = f.coordinator()
        try await f.install(["norm"], dl: dl)
        #expect(try Repair.loadCheck("norm", models: f.models).get() == f.models.install("norm"))
        let store = BlobStore(models: f.models)
        let (cfg, tok, w) = (f.blobs["config.json"]!, f.blobs["tokenizer.json"]!, f.blobs["model.safetensors"]!)
        // Truncate config, delete tokenizer, flip a byte in the weights (same size).
        chmod(store.url(cfg.sha256).path, 0o644); truncate(store.url(cfg.sha256).path, cfg.size / 2)
        try store.remove(tok.sha256)
        chmod(store.url(w.sha256).path, 0o644)
        let h = try FileHandle(forUpdating: store.url(w.sha256))
        try h.seek(toOffset: UInt64(w.size / 3)); let b = try h.read(upToCount: 1)!
        try h.seek(toOffset: UInt64(w.size / 3)); try h.write(contentsOf: Data([b[0] ^ 0x5A])); try h.close()

        let problems = Repair.check("norm", models: f.models)
        #expect(Set(problems) == [.size(path: "config.json", sha256: cfg.sha256), .missing(path: "tokenizer.json", sha256: tok.sha256),
                                  .digest(path: "model.safetensors", sha256: w.sha256)])
        guard case .failure(let e) = Repair.loadCheck("norm", models: f.models) else { Issue.record("load not refused"); return }
        #expect(e.is(.modelCorrupt))
        #expect(e.detail == "redownload=\(cfg.size + tok.size + w.size)")
        #expect(Repair.redownloadBytes(problems, models: f.models, id: "norm") == cfg.size + tok.size + w.size)

        let sentBefore = f.server.records().reduce(Int64(0)) { $0 + $1.sent }
        let fixed = try await Repair.run(f.catalog.models["norm"]!, catalogVersion: 7, coordinator: dl)
        #expect(fixed.count == 3)
        #expect(try Repair.loadCheck("norm", models: f.models).get() == f.models.install("norm"))
        let want = cfg.size + tok.size + w.size
        try await until(5) { f.server.records().reduce(Int64(0)) { $0 + $1.sent } >= sentBefore + want }
        try await Task.sleep(for: .milliseconds(200))
        let refetched = f.server.records().reduce(Int64(0)) { $0 + $1.sent } - sentBefore
        #expect(refetched == cfg.size + tok.size + w.size, "only the three bad blobs, got \(refetched)")
        ATLog.write("AT-NFR-S5", "repair.log", "truncate/delete/flip → model.corrupt (Re-download \(cfg.size + tok.size + w.size) B); Repair re-fetched exactly \(refetched) B; load OK; no crash (in-process check, no helper involved)")
    }

    /// NFR-SEC2 load-time half: a manifest that names a `.py` / `.pkl` / non-raw `.bin` never loads.
    @Test func forbiddenFileRefusedAtLoad() async throws {
        let f = try StoreFixture("sec2")
        try await f.install(["norm"])
        let url = f.models.install("norm").appending(path: "manifest.json")
        var m = try #require(InstallManifest.load(url))
        m.files["modeling_evil.py"] = f.blobs["config.json"]!.sha256
        m.sizes["modeling_evil.py"] = f.blobs["config.json"]!.size
        try m.encoded().write(to: url)
        try FilePlacement.symlink.place(BlobStore(models: f.models).url(f.blobs["config.json"]!.sha256),
                                        at: f.models.install("norm").appending(path: "modeling_evil.py"))
        #expect(Repair.check("norm", models: f.models).contains(.forbidden(path: "modeling_evil.py")))
        guard case .failure(let e) = Repair.loadCheck("norm", models: f.models) else { Issue.record("loaded a .py"); return }
        #expect(e.is(.modelCorrupt))
        for p in ["x.pkl", "pytorch_model.bin", "a.pt", "b.ckpt"] { #expect(CatalogModel.forbiddenFile(p)) }
        #expect(!CatalogModel.forbiddenFile("m.mlmodelc/weights/weight.bin"))
        ATLog.write("AT-NFR-SEC2", "load-time.log", "view naming modeling_evil.py → Repair.check .forbidden → load refused (model.corrupt); .pkl/.pt/.ckpt/pickle .bin forbidden, Core ML weight.bin allowed")
    }
}
