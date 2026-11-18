// M3.T10: the helper's `VoiceSessionServing` — one `VoiceSession` per `VoiceSessionStart.requestID`. A session needs
// the verified Voice pack (stt, vad-files, turn-coreml, tts; `voice.unavailable` otherwise: Basic voice covers
// dictation and read aloud, not conversations) and Kokoro (on macOS 26.4–26.5, K-NEW-ENG-9, the conversation answers
// `voice.unavailable` too: the system voice cannot play into the VPIO graph's echo reference). Models are leased through
// the scheduler for the whole session (resident while it runs); each user turn gets its own recogniser (Parakeet +
// streaming EOU for English, WhisperKit routing as dictation, `STTService.parakeet`).
// M3 review P0-1 / P1-1: a session exists from the moment its start is routed (`prepare`), before its models are
// leased: an End in that window is remembered and the session never starts capture; controls (mute, push-to-talk) are
// queued and applied in order once capture runs. P0-2 / P2-3: a session that cannot go on (no recogniser, capture lost)
// is ended here — capture off, leases released — and only then is the error sent as the stream's terminal.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import SpeechSwiftVendored
import Synchronization

public final class VoiceSessionService: VoiceSessionServing {
    public typealias PartsFactory = @Sendable (VoiceSessionStart, VoiceModelSet) async throws -> VoiceSessionParts

    private let parts: PartsFactory
    private enum Entry {
        /// Models leasing / capture starting: an End (`ended`), a fatal error and the controls wait here.
        case building(ended: Bool, error: AntiChatError?, controls: [VoiceSessionControl.Action])
        case running(VoiceSession, VoiceEmit)
    }
    private let sessions = LockedBox<[UUID: Entry]>([:])
    /// AT-FA-05: how a running session was ended (`finish`). `start` sends that terminal itself once the session has
    /// ended: the request's body must not return before its terminal is out, or the router closes the stream with
    /// `engine.noTerminal` first (it did, at the end of a spoken turn, in the clean VM).
    private let endings = LockedBox<[UUID: AntiChatError?]>([:])

    public init(parts: @escaping PartsFactory) { self.parts = parts }

    /// The helper's sessions: models through the scheduler, the device (or ScriptedVoice in DEBUG).
    public static func helper(provider: any VoiceModelProvider) -> VoiceSessionService {
        VoiceSessionService { start, models in try await standardParts(start, models, provider: provider, live: nil) }
    }

    /// `live` nil = the microphone unless `start.scriptedInput` (DEBUG); a capture source = that source (tests).
    public static func standardParts(
        _ start: VoiceSessionStart, _ models: VoiceModelSet, provider: any VoiceModelProvider,
        live: (any AudioCaptureSource)?, sink: (any VoiceOutputSink)? = nil
    ) async throws -> VoiceSessionParts {
        guard let stt = models.slots[.stt], let vad = models.slots[.vad], let turn = models.slots[.turn],
              let tts = models.slots[.tts] else {
            throw AntiChatError.voice("unavailable", "voice conversation needs the Voice pack")
        }
        guard KokoroBackend.osAllowsKokoro() else {
            throw AntiChatError.voice("unavailable", "voice conversation needs Kokoro (K-NEW-ENG-9)")
        }
        // M3 review P0-2: a spoken language outside Parakeet's needs `stt-multi`; without it every turn would fail.
        if case .whisper = LanguageRouter.route(setting: start.locale), models.slots[.sttMulti] == nil {
            throw AntiChatError.voice("unavailable", "stt-multi (other languages) is not installed")
        }
        var leases: [VoiceModelLease] = []
        do {
            let t = try await provider.lease(.turn, turn)
            leases.append(t)
            let k = try await provider.lease(.tts, tts)
            leases.append(k)
            leases.append(try await provider.lease(.stt, stt))  // keeps Parakeet resident between turns
            guard let smart = t.object as? SmartTurnModel else { throw AntiChatError.voice("modelMismatch", "turn-coreml") }
            guard let synth = k.object as? any SpeechSynthesizing else { throw AntiChatError.voice("modelMismatch", "tts") }
            try? smart.prewarm()
            let silero = try SileroVADProvider(directory: URL(fileURLWithPath: vad.path))
            var injected: (any AudioCaptureSource)? = live
            #if DEBUG || ANTICHAT_PERF_HARNESS
            if injected == nil, let script = start.scriptedInput {
                injected = try ScriptedVoice(script: URL(fileURLWithPath: script))
            }
            #endif
            let isLive = injected == nil
            // M3.T12: the output route decides full / half duplex and the ducking (`HalfDuplexPolicy.plan`).
            var fake: [String: String] = [:]
            #if DEBUG || ANTICHAT_PERF_HARNESS
            for kv in (start.fakeAudio ?? "").split(separator: ",") {
                let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if p.count == 2 { fake[p[0]] = p[1] }
            }
            #endif
            let route: VoiceAudioRoute = switch fake["route"] {
            case "headphones": .headphones
            case "speakers": .speakers
            case "noaec": .noEchoCancellation
            // `-FakeAEC unavailable` with scripted input stands for speakers whose VPIO failed.
            default: isLive ? VoiceAudioRouteProbe.current() : fake["aec"] == "unavailable" ? .speakers : .injected
            }
            let plan = HalfDuplexPolicy.plan(route: route, duckOthers: start.duckOthers)
            // Live input is a plain mic tap (no route runs VPIO since 0.0.8; speakers are half duplex instead); injected
            // input plays into a silent clock (mode inject [IN-PIPELINE]).
            // 0.0.8: live, the reply plays on a plain engine (`PlainPlaybackDevice`), never through VPIO.
            let audio = VoiceAudioEngine(injected: injected, enableAEC: plan.voiceProcessing, duckingMinimum: plan.duckingMin ?? false,
                                         preferBuiltInMic: plan.preferBuiltInMic, inputDeviceUID: start.deviceUID)
            let fakeAECUnavailable = fake["aec"] == "unavailable"
            // A device change re-probes the route and rebuilds with its plan (live only, no faked route).
            let routeNow = LockedBox(route)
            if isLive, fake["route"] == nil {
                let duck = start.duckOthers
                audio.planOnRebuild = {
                    let r = VoiceAudioRouteProbe.current()
                    routeNow.withLock { $0 = r }
                    let p = HalfDuplexPolicy.plan(route: r, duckOthers: duck)
                    return (p.voiceProcessing, p.duckingMin ?? false, p.preferBuiltInMic)
                }
            }
            AppLog.log(.voice, .info, "voice session: route \(route.rawValue), VPIO \(plan.voiceProcessing), duck min \(plan.duckingMin ?? false)")
            let output: any VoiceOutputSink = sink ?? (isLive ? DuplexOutputSink(audio: audio) : ClockedSilentSink())
            let dictation = DictationStart(locale: start.locale)
            let synthesis = PresynthesizingSynth(synth)  // A-M3-T09c
            var parts = VoiceSessionParts(
                capture: audio, live: isLive, vad: silero, smartTurn: smart,
                recogniser: { try await STTService.parakeet(dictation, models, provider) },
                synthesiser: { KokoroBackend(tts: synthesis, playback: $0) },
                sink: output, leases: leases,
                // The key KokoroBackend.speak uses: the voice id (empty = default) and the clamped rate.
                presynthesize: { text, voice, rate in
                    synthesis.presynthesize(text, voice: voice.isEmpty ? nil : voice, speed: min(1.5, max(0.75, rate)))
                },
                route: route, voiceProcessing: plan.voiceProcessing || fakeAECUnavailable,
                aecFailed: { fakeAECUnavailable || audio.echoCancellationFailed },
                duckingLevel: { audio.appliedDuckingLevel },
                currentPlan: {
                    let r = routeNow.withLock { $0 }
                    return (r, HalfDuplexPolicy.plan(route: r, duckOthers: start.duckOthers).voiceProcessing || fakeAECUnavailable)
                })
            if isLive { parts.watchDevice = { handler in audio.onGraphFailed = handler } }
            return parts
        } catch {
            for l in leases { await l.release() }
            throw error
        }
    }

    public func prepare(_ id: UUID) {
        sessions.withLock { if $0[id] == nil { $0[id] = .building(ended: false, error: nil, controls: []) } }
    }

    public func start(_ start: VoiceSessionStart, models: VoiceModelSet, emit: @escaping VoiceEmit) async {
        let id = start.requestID
        prepare(id)
        let parts: VoiceSessionParts
        do { parts = try await self.parts(start, models) } catch {
            sessions.withLock { $0[id] = nil }
            return emit([.engine(.error(error as? AntiChatError ?? .voice("unavailable", "\(error)")))])
        }
        // Ended (or the request cancelled) while the models were leasing: capture never starts.
        if case .building(ended: true, error: let error, controls: _)? = sessions.withLock({ $0[id] }) {
            sessions.withLock { $0[id] = nil }
            for l in parts.leases { await l.release() }
            return emit([error.map { .engine(.error($0)) } ?? .engine(.done(.stop))])
        }
        if Task.isCancelled {
            sessions.withLock { $0[id] = nil }
            for l in parts.leases { await l.release() }
            return emit([.engine(.done(.cancelled))])
        }
        let session = VoiceSession(start: start, parts: parts, emit: emit) { [weak self] error in
            Task { await self?.fail(id, error) }
        }
        do { try await session.begin() } catch {
            sessions.withLock { $0[id] = nil }
            await session.end()
            return emit([.engine(.error(.voice("noDevice", "\(error)")))])
        }
        // Apply the controls that arrived meanwhile, in order, then hand the session to `control` / `end`.
        enum Next { case apply([VoiceSessionControl.Action]), running, ended(AntiChatError?) }
        while true {
            let next = sessions.withLock { s -> Next in
                guard case .building(let ended, let error, let controls)? = s[id] else { return .ended(nil) }
                if ended {
                    s[id] = nil
                    return .ended(error)
                }
                if controls.isEmpty {
                    s[id] = .running(session, emit)
                    return .running
                }
                s[id] = .building(ended: false, error: nil, controls: [])
                return .apply(controls)
            }
            switch next {
            case .apply(let controls):
                for c in controls { await session.control(c) }
                continue
            case .ended(let error):
                await session.end()
                return emit([error.map { .engine(.error($0)) } ?? .engine(.done(.stop))])
            case .running:
                break
            }
            break
        }
        // The request lives as long as the session (the router closes a request whose body returns); a cancelled
        // request (the app dropped the stream) ends the session like `VoiceSessionEnd`.
        await withTaskCancellationHandler {
            await session.untilEnded()
        } onCancel: {
            Task { await self.end(VoiceSessionEnd(requestID: id)) }
        }
        let ending = endings.withLock { $0.removeValue(forKey: id) } ?? nil
        emit([ending.map { .engine(.error($0)) } ?? .engine(.done(.stop))])
    }

    public func control(_ control: VoiceSessionControl) async {
        let running = sessions.withLock { s -> VoiceSession? in
            switch s[control.requestID] {
            case .building(let ended, let error, var controls)?:
                if !ended { controls.append(control.action) }
                s[control.requestID] = .building(ended: ended, error: error, controls: controls)
                return nil
            case .running(let session, _)?: return session
            case nil: return nil
            }
        }
        await running?.control(control.action)
    }

    public func end(_ end: VoiceSessionEnd) async {
        await finish(end.requestID, nil)
    }

    /// A fatal error from the running session (P0-2 / P2-3): end it, then the error is the terminal.
    func fail(_ id: UUID, _ error: AntiChatError) async {
        await finish(id, error)
    }

    private func finish(_ id: UUID, _ error: AntiChatError?) async {
        let running = sessions.withLock { s -> VoiceSession? in
            switch s[id] {
            case .building(let ended, let earlier, _)?:
                s[id] = .building(ended: true, error: ended ? earlier : error, controls: [])
                return nil
            case .running(let session, _)?:
                s[id] = nil
                endings.withLock { $0[id] = .some(error) }  // `start` sends it once `end` returned
                return session
            case nil: return nil
            }
        }
        await running?.end()
    }

    /// Whether a session `id` exists (building or running). Tests wait on it.
    func exists(_ id: UUID) -> Bool { sessions.withLock { $0[id] != nil } }

    /// The running session `id` (perf probes, tests).
    public func session(_ id: UUID) -> VoiceSession? {
        sessions.withLock { if case .running(let s, _)? = $0[id] { s } else { nil } }
    }
}
