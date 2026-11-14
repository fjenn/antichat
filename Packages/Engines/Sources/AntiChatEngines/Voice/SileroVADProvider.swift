// M3.T09 step 2: live Silero for the voice conversation, conforming to the vendored `StreamingVADProvider`
// (speech-swift StreamingVADProcessor feeds it 512-sample / 32 ms frames). A-M3-T01a (d): live Silero runs as Core ML
// (`vad-files`, silero-vad-unified-v6.0.0, the same model M0.T05 and dictation use) on CPU/ANE compute units, never the
// GPU (K-NEW-ENG-10); ORT is not linked into AntiChatEngines. The LSTM state and the 64-sample context carry across
// frames (`SileroFrameVAD`) and reset per turn stream.
@preconcurrency import CoreML
import Foundation
import SpeechSwiftVendored

public enum SileroVADProviderError: Error, Equatable, Sendable {
    case inference(String)
}

/// Silero v6 (Core ML) one 32 ms frame at a time. Calls are serialised by the capture worker.
public final class SileroVADProvider: StreamingVADProvider, @unchecked Sendable {
    public let inputSampleRate = 16_000
    public let chunkSize = SileroFrameVAD.frame
    /// The last inference error; a failed frame scores 0 (silence), and `TurnDetector` reports the error.
    public private(set) var lastError: SileroVADProviderError?

    private let vad: SileroFrameVAD

    /// `directory` is the `vad-files` install (holds `silero-vad-unified-v6.0.0.mlmodelc`).
    public init(directory: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        vad = try SileroFrameVAD(directory: directory, computeUnits: computeUnits)
    }

    public func processChunk(_ samples: [Float]) -> Float {
        guard samples.count == chunkSize else {
            lastError = .inference("Silero expects \(chunkSize) samples, got \(samples.count)")
            return 0
        }
        do {
            let p = try vad.probability(samples[...])
            lastError = nil
            return p.isFinite ? min(1, max(0, p)) : 0
        } catch {
            lastError = .inference("\(error)")
            return 0
        }
    }

    public func resetState() {
        vad.reset()
        lastError = nil
    }
}
