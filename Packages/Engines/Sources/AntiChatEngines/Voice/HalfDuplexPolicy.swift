// M3.T12 (R-280 AC2/AC3, P-media-03): when a conversation runs full duplex (barge-in by voice, VPIO echo
// cancellation) and when it falls back to half duplex (the mic is gated while the assistant speaks + 300 ms, barge-in
// by voice off, `voice.headphones` hint once). Pure; `VoiceSession` feeds it and applies the result.
//   Triggers: VPIO could not be enabled; an output device without echo cancellation support; the AEC residual check
//   (during the session's first assistant chunk, Silero P(speech) ≥ 0.5 on > 30 % of the frames while the user was
//   silent, i.e. no barge-in was confirmed). A headphone route is always full duplex (no echo path).
//   Ducking (R-280 AC3): `duckOthers` on → VPIO ducks other audio to the minimum level; off → on headphones the session
//   runs without VPIO (nothing is ducked), on speakers VPIO stays (AC1 needs AEC) at the minimum ducking level.
import Foundation

/// The output route of a conversation, as far as echo goes.
public enum VoiceAudioRoute: String, Sendable, Equatable {
    /// Built-in speakers (or any device whose output reaches the microphone): needs echo cancellation.
    case speakers
    /// Headphones, AirPods, a headset: no echo path.
    case headphones
    /// An output device VPIO cannot cancel (e.g. an aggregate / HDMI / AirPlay device).
    case noEchoCancellation
    /// Scripted input (ScriptedVoice, tests): no acoustic path at all.
    case injected

    /// No echo can reach the microphone: always full duplex.
    public var echoFree: Bool { self == .headphones || self == .injected }
}

public struct HalfDuplexPolicy: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case aecUnavailable, routeWithoutAEC, residualEcho
    }

    /// The audio graph a session starts with.
    public struct Plan: Sendable, Equatable {
        /// Run the input through VPIO (echo cancellation + ducking).
        public var voiceProcessing: Bool
        /// VPIO's other-audio ducking at the minimum level (`AVAudioVoiceProcessingOtherAudioDuckingConfiguration
        /// (enableAdvancedDucking: false, duckingLevel: .min)`); nil when VPIO is off.
        public var duckingMin: Bool?
    }

    public static let residualThreshold: Float = 0.5
    public static let residualShare = 0.30
    /// The mic stays gated this long after the reply's audio ends (half duplex).
    public static let tailMs = 300

    public private(set) var halfDuplex: Reason?
    public let route: VoiceAudioRoute
    private var residualFrames = 0
    private var residualVoiced = 0
    private var residualDone = false

    public init(route: VoiceAudioRoute) {
        self.route = route
    }

    /// The graph for `route` and the ducking setting (step 1).
    public static func plan(route: VoiceAudioRoute, duckOthers: Bool) -> Plan {
        switch (route, duckOthers) {
        case (.headphones, false), (.injected, _): Plan(voiceProcessing: false, duckingMin: nil)
        default: Plan(voiceProcessing: true, duckingMin: true)
        }
    }

    /// The graph started (`voiceProcessing` = VPIO was requested; `aecStarted` = it is running). Returns the reason
    /// when the session must run half duplex from the start.
    public mutating func started(voiceProcessing: Bool, aecStarted: Bool) -> Reason? {
        guard !route.echoFree, halfDuplex == nil else { return halfDuplex }
        if route == .noEchoCancellation { halfDuplex = .routeWithoutAEC }
        else if voiceProcessing, !aecStarted { halfDuplex = .aecUnavailable }
        return halfDuplex
    }

    /// One input frame while the session's first assistant chunk plays (`probability` = Silero); judged at
    /// `firstChunkEnded`.
    public mutating func firstChunkFrame(probability: Float) {
        guard !residualDone, halfDuplex == nil, !route.echoFree else { return }
        residualFrames += 1
        if probability >= Self.residualThreshold { residualVoiced += 1 }
    }

    /// The first chunk finished playing. `bargedIn` = the user interrupted it (the frames were the user's voice,
    /// so they say nothing about the echo; the check moves on to the next chunk). Returns the switch, if any.
    public mutating func firstChunkEnded(bargedIn: Bool) -> Reason? {
        guard !residualDone, halfDuplex == nil, !route.echoFree else { return nil }
        if bargedIn {
            residualFrames = 0
            residualVoiced = 0
            return nil
        }
        guard residualFrames > 0 else { return nil }
        residualDone = true
        if Double(residualVoiced) / Double(residualFrames) > Self.residualShare {
            halfDuplex = .residualEcho
            return .residualEcho
        }
        return nil
    }

    /// The share of voiced frames measured so far (logs).
    public var residualVoicedShare: Double { residualFrames == 0 ? 0 : Double(residualVoiced) / Double(residualFrames) }
    public var residualChecked: Bool { residualDone }
}
