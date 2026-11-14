// The engine adapter contract in the helper (R-229; M1.T05). Every chat engine (MLX, llama-server, scripted)
// turns one `ChatRequest` into an ordered stream of the seven `EngineEvent`s, interleaved with
// `LifecycleEvent`s, ending with exactly one terminal event (`done` or `error`). Cancellation = cancelling the
// consuming Task (the stream's termination cancels the producer). The DeltaBatcher sits after the adapter.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

/// One item of an adapter stream, in production order.
public enum AdapterOutput: Sendable, Hashable {
    case event(EngineEvent)
    case lifecycle(LifecycleEvent)
}

/// Per-request context the host passes to the adapter.
public struct GenerationContext: Sendable {
    /// When the helper received the request (Usage.ttftMs is measured from here).
    public var receivedAt: ContinuousClock.Instant
    /// Model load time when this request triggered the load (seconds).
    public var loadTime: Double?

    public init(receivedAt: ContinuousClock.Instant = .now, loadTime: Double? = nil) {
        self.receivedAt = receivedAt
        self.loadTime = loadTime
    }
}

public protocol EngineAdapter: Actor {
    nonisolated var kind: EngineKind { get }
    var loadedKey: String? { get }
    /// Makes `slot` resident; returns the load wall time in seconds (0 when already resident).
    @discardableResult func load(_ slot: ModelSlot) async throws -> Double
    func unload() async
    /// Streams one turn. Throws only before streaming starts (e.g. model not loaded); later failures are a
    /// terminal `.event(.error(_))`.
    func generate(_ request: ChatRequest, context: GenerationContext) async throws -> AsyncStream<AdapterOutput>
}

extension AsyncStream.Continuation where Element == AdapterOutput {
    func event(_ e: EngineEvent) { yield(.event(e)) }
}

enum EngineTime {
    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    static func ms(_ d: Duration) -> Double { secs(d) * 1000 }
}
