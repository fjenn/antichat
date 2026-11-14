// M3.T03 step 6 (R-050 AC3): voiced-frame detection for dictation — speech onset (NFR-V6 start) and the
// silence-only rule (no voiced frame → empty result, no recogniser pass). Silero v6 (`vad-files`, Core ML on CPU/ANE,
// never the GPU) when installed; an energy gate otherwise (−45 dBFS over a 32 ms frame).
// `SchedulerVoiceModels` is the production `VoiceModelProvider`: a lease through the ModelScheduler (the one load
// authority, budget B and eviction E.2.7), with the Core ML objects built by `VoiceModelResidency` materializers.
@preconcurrency import CoreML
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public protocol VoiceActivityDetector: AnyObject, Sendable {
    var frameSamples: Int { get }
    /// Called on one thread at a time (the capture thread), frames in order.
    func isVoiced(_ frame: [Float]) -> Bool
}

public final class SileroVAD: VoiceActivityDetector, @unchecked Sendable {
    public let frameSamples = SileroFrameVAD.frame
    public let threshold: Float
    private let vad: SileroFrameVAD

    public init(directory: URL, threshold: Float = 0.5) throws {
        vad = try SileroFrameVAD(directory: directory, computeUnits: .cpuAndNeuralEngine)
        self.threshold = threshold
    }

    public func isVoiced(_ frame: [Float]) -> Bool { ((try? vad.probability(frame[...])) ?? 0) >= threshold }
}

public final class EnergyVAD: VoiceActivityDetector, @unchecked Sendable {
    public let frameSamples = 512
    public let dBFS: Double

    public init(dBFS: Double = -45) { self.dBFS = dBFS }

    public func isVoiced(_ frame: [Float]) -> Bool { rmsDBFS(frame) >= dBFS }
}

public struct SchedulerVoiceModels: VoiceModelProvider {
    let scheduler: ModelScheduler
    let residency: VoiceModelResidency

    /// Registers the Core ML materializers for the STT roles on `residency`.
    public init(scheduler: ModelScheduler, residency: VoiceModelResidency) {
        self.scheduler = scheduler
        self.residency = residency
        residency.setMaterializer(VoiceModelRole.stt.catalogKey) { try await ParakeetModel.load(directory: URL(fileURLWithPath: $0.path)) }
        residency.setMaterializer(VoiceModelRole.sttEOU.catalogKey) { try await ParakeetEOUModel.load(directory: URL(fileURLWithPath: $0.path)) }
        residency.setMaterializer(VoiceModelRole.sttMulti.catalogKey) { try await WhisperKitModel.load(directory: URL(fileURLWithPath: $0.path)) }
        residency.setMaterializer(VoiceModelRole.turn.catalogKey) { try SmartTurnLoader.load(turnDirectory: URL(fileURLWithPath: $0.path)) }
        residency.setMaterializer(VoiceModelRole.tts.catalogKey) { try await KokoroTTS.load(slotDirectory: URL(fileURLWithPath: $0.path)) }
    }

    public func lease(_ role: VoiceModelRole, _ slot: ModelSlot) async throws -> VoiceModelLease {
        let token = try await scheduler.ensureLoaded(role: role.residency, model: slot)
        guard let object = residency.object(slot.key) else {
            await scheduler.release(token)
            throw AntiChatError.voice("modelNotResident", slot.key)
        }
        let scheduler = scheduler
        return VoiceModelLease(object: object) { await scheduler.release(token) }
    }
}
