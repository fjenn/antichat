// M3.T01 step 5: residency of the Core ML voice models (`EngineKind.coreml`) under the one load authority
// (ModelScheduler, M2.T12). The scheduler decides when a voice model may be resident (budget B, eviction rank
// E.2.7 via `VoiceModelRole.residency`); this table records the decision and checks the model directory exists
// (D-11: only the model store's paths, never a download). M3.T03: a backend registers a *materializer* per catalog
// key (Parakeet `stt`, the streaming `stt-eou`); `load` then builds the Core ML objects inside the scheduler's load,
// so a hover warm-up (NFR-V10) really compiles the model and the measured load time is the real one. `object(key)`
// hands the built object to the backend; `unload` drops it (eviction under pressure or budget).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization

public final class VoiceModelResidency: Sendable {
    public typealias Materializer = @Sendable (ModelSlot) async throws -> any Sendable
    private let resident = Mutex<[String: ModelSlot]>([:])
    private let objects = Mutex<[String: any Sendable]>([:])
    private let materializers = Mutex<[String: Materializer]>([:])
    private let onUnload = Mutex<[@Sendable (String) -> Void]>([])

    public init() {}

    public static func handles(_ slot: ModelSlot) -> Bool { slot.engine == .coreml }

    /// Builds the Core ML object of catalog key `key` during its load (one per key; the last registration wins).
    public func setMaterializer(_ key: String, _ build: @escaping Materializer) {
        materializers.withLock { $0[key] = build }
    }

    public func load(_ slot: ModelSlot) async throws -> Double {
        let t0 = ContinuousClock.now
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: slot.path, isDirectory: &isDir), isDir.boolValue else {
            throw AntiChatError(.modelMissing, detail: "\(slot.key): \(slot.path)")
        }
        if let build = materializers.withLock({ $0[slot.key] }) {
            let object = try await build(slot)
            objects.withLock { $0[slot.key] = object }
        }
        resident.withLock { $0[slot.key] = slot }
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// The object the materializer built for resident `key` (nil when not resident or no materializer).
    public func object(_ key: String) -> (any Sendable)? { objects.withLock { $0[key] } }

    public func unload(_ key: String) {
        objects.withLock { _ = $0.removeValue(forKey: key) }
        guard resident.withLock({ $0.removeValue(forKey: key) }) != nil else { return }
        for f in onUnload.withLock({ $0 }) { f(key) }
    }

    public func holds(_ key: String) -> Bool { resident.withLock { $0[key] != nil } }

    public var keys: [String] { resident.withLock { $0.keys.sorted() } }

    /// Backends drop their Core ML objects for `key` here (eviction under pressure or budget).
    public func observeUnload(_ f: @escaping @Sendable (String) -> Void) { onUnload.withLock { $0.append(f) } }
}
