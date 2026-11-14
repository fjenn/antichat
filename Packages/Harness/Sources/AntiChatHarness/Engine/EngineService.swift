// What the harness talks to (M1.T05 step 5/6): the XPC `EngineClient` in normal runs, the in-process
// `InProcessScriptedEngine` under `-UseScriptedEngine <path>` (no XPC, no helper). TurnController (M1.T06) and
// everything above it only see this protocol.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public protocol EngineService: AnyObject, Sendable {
    /// Composer focus / mic hover (architecture §4.2): connect lazily and preload `slot`. Never at launch.
    /// Returns when the model is ready or the warmup failed (the error, if any).
    @discardableResult
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError?

    /// One turn. The stream yields the seven `EngineEvent`s and ends after exactly one terminal (`done` or
    /// `error`); engine failures are `.error` events, never thrown. Lifecycle events go to `onLifecycle`.
    /// Cancelling the consuming Task sends `Cancel{requestID}` (the stream then ends with `done(cancelled)`).
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error>

    /// `Cancel{requestID}`: answered with `done(cancelled)` within ≤ 300 ms (NFR-U6).
    func cancel(_ requestID: UUID)

    /// The engine's capabilities once known (after the handshake / script load).
    func capabilities() async -> EngineCapabilities?

    /// M2.T15 (R-206 AC5): a predictive warm-up hint (ModeSwitch / ⇧⌘E / mic hover). Fire-and-forget: returns once
    /// the helper accepted it; the load runs there at `.utility`. Engines without a scheduler ignore it.
    func hint(_ warmup: Warmup) async

    /// M6.T02 (R-270 AC1): token counts by the slot's tokenizer (`CountTokens`). Engines without one (the scripted
    /// replay) estimate ⌈characters / 4⌉.
    func countTokens(_ texts: [String], slot: ModelSlot) async -> [Int]

    /// M3.T01/T03: a stream-opening voice message (dictation start, file, session start, speak, model registration);
    /// the stream carries `VoiceEvent`s and ends with one terminal engine event. Engines without the voice service
    /// (the in-process scripted replay) answer `voice.unavailable`.
    func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch>

    /// M3.T01/T03: a message acting on an open voice stream (dictation stop, …); false when it could not be sent.
    @discardableResult
    func voiceSend(_ message: VoiceMessage) -> Bool
}

extension EngineService {
    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        chat(request, onLifecycle: nil)
    }

    @discardableResult
    public func warmup(_ slot: ModelSlot) async -> AntiChatError? {
        await warmup(slot, onLifecycle: nil)
    }

    public func hint(_ warmup: Warmup) async {}

    public func countTokens(_ texts: [String], slot: ModelSlot) async -> [Int] { texts.map(CountTokensRequest.estimate) }

    public func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch> {
        AsyncStream { c in
            c.yield(EngineBatch(items: [.engine(.error(.voice("unavailable", "no voice service in this engine")))]))
            c.finish()
        }
    }

    @discardableResult
    public func voiceSend(_ message: VoiceMessage) -> Bool { false }
}

public enum EngineServices {
    /// The service for this process: `-UseScriptedEngine <path>` (DEBUG launch option) → in-process replay, else XPC.
    public static func make(options: LaunchOptions = .current, appBuild: String = "dev") -> any EngineService {
        if let path = options.scriptedEngineScript {
            do {
                return try InProcessScriptedEngine(scriptPath: path)
            } catch {
                AppLog.log(.engine, .error, "-UseScriptedEngine \(path): \(error); falling back to the XPC engine")
            }
        }
        // M1.T12: the supervised client (helper restart choreography, crash loop, memory-fit guard).
        return EngineSupervisorClient(appBuild: appBuild, fitGuard: devFitGuard(options: options))
    }

    /// M3.T03: the engine voice goes to. Capture and STT run in the helper (contract 1), so a window whose chat
    /// replay is in-process (`-UseScriptedEngine`, UI tests) still sends voice to the XPC helper.
    public static func voice(for engine: any EngineService, appBuild: String = "dev") -> any EngineService {
        engine is InProcessScriptedEngine ? sharedVoiceClient(appBuild) : engine
    }

    /// M4 (scripted in-app flow): where media jobs go. The XPC engine is its own transport; an in-process scripted chat
    /// engine (`-UseScriptedEngine`, no helper of its own) sends media jobs to the shared XPC helper, like voice — so
    /// create_image / edit_image exist and run through the helper's runner and gate (`-UseScriptedImageEngine`).
    public static func mediaTransport(for engine: any EngineService, appBuild: String = "dev") -> (any MediaJobTransport)? {
        if let t = engine as? any MediaJobTransport { return t }
        return engine is InProcessScriptedEngine ? sharedVoiceClient(appBuild) : nil
    }

    nonisolated(unsafe) private static var voiceClient: EngineSupervisorClient?
    nonisolated(unsafe) private static var voiceGuard: MemoryFitGuard?
    private static let voiceLock = NSLock()
    private static func sharedVoiceClient(_ appBuild: String) -> EngineSupervisorClient {
        voiceLock.withLock {
            if let c = voiceClient { return c }
            let c = EngineSupervisorClient(appBuild: appBuild, fitGuard: voiceGuard)
            voiceClient = c
            return c
        }
    }

    /// The composition root's memory-fit guard for the shared voice client (`AppVoiceWiring.attach`); a client made
    /// before it is replaced, so the guard is never lost to an early caller.
    public static func setVoiceFitGuard(_ guard_: MemoryFitGuard?) {
        voiceLock.withLock {
            voiceGuard = guard_
            if let c = voiceClient, c.fitGuard == nil { voiceClient = nil }
        }
    }

    /// The memory-fit guard the app wires everywhere: the dev catalog's (`ANTICHAT_DEV_CATALOG`) when given, else a
    /// free-memory guard with the tier budget (`-FakeHardware`) and no catalog entries yet (M2's signed catalog).
    public static func appFitGuard(options: LaunchOptions = .current,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> MemoryFitGuard {
        devFitGuard(options: options, environment: environment)
            ?? MemoryFitGuard(entries: [:], budgetBytes: options.fakeHardware.map(MemoryFitGuard.budget(for:)),
                              resolve: MemoryFitGuard.devResolver())
    }

    /// The M1 memory-fit guard over the dev catalog (`ANTICHAT_DEV_CATALOG=<catalog/dev-catalog.json>`), with B
    /// from `-FakeHardware` (else free memory only). nil without a catalog: M2's signed catalog replaces this.
    public static func devFitGuard(options: LaunchOptions = .current,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> MemoryFitGuard? {
        guard let path = environment["ANTICHAT_DEV_CATALOG"],
              let entries = try? MemoryFitGuard.loadDevCatalog(URL(fileURLWithPath: path))
        else { return nil }
        return MemoryFitGuard(
            entries: entries, budgetBytes: options.fakeHardware.map(MemoryFitGuard.budget(for:)),
            resolve: MemoryFitGuard.devResolver())
    }
}
