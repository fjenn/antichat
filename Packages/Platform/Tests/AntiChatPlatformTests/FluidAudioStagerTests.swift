// M2.T08 step 7: FluidAudio's models are staged from store blobs into the folder it expects, atomically, as clones.
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct FluidAudioStagerTests {
    @Test func stagesClonesAtomically() throws {
        let dir = DL.tempDir("fa")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try DL.makeBlob(in: dir, name: "a", size: 4096, seed: 1)
        let b = try DL.makeBlob(in: dir, name: "b", size: 100, seed: 2)
        let dest = dir.appending(path: "FluidAudio/Models/silero-vad-coreml")
        try FluidAudioStager.stage(files: ["silero-vad.mlmodelc/weights/weight.bin": a.url, "silero-vad.mlmodelc/model.mil": b.url], into: dest)
        let w = dest.appending(path: "silero-vad.mlmodelc/weights/weight.bin")
        #expect(try Verify.sha256(w) == a.sha256)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: w.path)) == nil, "a clone, not a symlink")
        #expect(!FileManager.default.fileExists(atPath: dest.path + ".staging"))
        // Re-staging replaces the folder.
        try FluidAudioStager.stage(files: ["only.bin": b.url], into: dest)
        #expect(!FileManager.default.fileExists(atPath: w.path))
        #expect(throws: (any Error).self) { try FluidAudioStager.stage(files: ["../escape": a.url], into: dest) }
    }
}
