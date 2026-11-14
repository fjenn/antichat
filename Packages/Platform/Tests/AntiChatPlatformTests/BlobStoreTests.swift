// AT-293 (R-293 AC1) + AT-NFR-D5 — M2.T10: files are stored once by sha256; Normal and Evil share the tokenizer blob;
// install views hold only symlinks (or clones) and a manifest; the store holds no two identical files.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct BlobStoreTests {
    @Test func sharedFilesStoredOnce() async throws {
        let f = try StoreFixture("blob")
        try await f.install(["norm", "evil"])
        let store = BlobStore(models: f.models)
        #expect(Set(store.all()) == Set(f.blobs.values.map(\.sha256)))  // 4 unique files, tokenizer once
        #expect(store.all().count == 4)
        let tok = f.blobs["tokenizer.json"]!.sha256
        for id in ["norm", "evil"] {
            let link = f.models.install(id).appending(path: "tokenizer.json")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))?.hasSuffix("store/sha256/\(tok.prefix(2))/\(tok)") == true)
            #expect(try Verify.sha256(link) == tok)
        }
        // No regular files in installs/ except manifest.json / .verified (both engines here use symlinks).
        let e = FileManager.default.enumerator(at: f.models.installs, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
        let regular = e.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !["manifest.json", ".verified"].contains($0.lastPathComponent)
        }
        #expect(regular.isEmpty, "\(regular)")
        // NFR-D5: no sha256-identical file twice in the store.
        let hashes = try store.all().map { try Verify.sha256(store.url($0)) }
        #expect(hashes.count == Set(hashes).count)
        #expect(f.models.installedManifests().map(\.modelID) == ["evil", "norm"])
        ATLog.write("AT-293", "unit.log", "BlobStore: Normal + Evil (shared tokenizer) → 4 blobs for 5 view files; views are symlinks only; no duplicate sha256 (NFR-D5)")
    }

    @Test func clonePlacementForCoreML() throws {
        #expect(InstallView.placement(engine: "coreml") == .clone)
        #expect(InstallView.placement(engine: "mlx-swift-lm") == .symlink)
        let dir = DL.tempDir("clone")
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try DL.makeBlob(in: dir, name: "w.bin", size: 4096)
        try FilePlacement.clone.place(b.url, at: dir.appending(path: "v/weights/weight.bin"))
        #expect(try Verify.sha256(dir.appending(path: "v/weights/weight.bin")) == b.sha256)
        try FilePlacement.symlink.place(b.url, at: dir.appending(path: "s/a/b.bin"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "s/a/b.bin").path) == "../../w.bin")
    }
}
