// Parakeet TDT final transcript (M0.T05 step 2; P-media-02). FluidAudio 0.18.0 `AsrManager` on the pinned
// `stt` directory (FluidInference/parakeet-ultra-coreml@95eaa59), loaded with `AsrModels.loadLocal`
// (no repository resolution, no download; ModelHub.offlineMode is on in the helper, D-11).
import FluidAudio
import Foundation

public actor ParakeetSTT {
    private let manager: AsrManager

    public static func load(directory: URL) async throws -> ParakeetSTT {
        let models = try AsrModels.loadLocal(from: directory, version: .ultra)
        let m = AsrManager(config: .default, models: models)
        return ParakeetSTT(manager: m)
    }

    private init(manager: AsrManager) {
        self.manager = manager
    }

    /// 16 kHz mono samples → final text.
    public func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make()
        // Parakeet needs ≥ 1 s of input; pad short turns with trailing silence.
        var x = samples
        if x.count < 16_000 { x += [Float](repeating: 0, count: 16_000 - x.count) }
        return try await manager.transcribe(x, decoderState: &state).text
    }
}
