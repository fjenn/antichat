// Kokoro 82M on the ANE (M0.T05 step 2; P-media-04): FluidAudio 0.18.0 `KokoroAneManager` (English,
// legacy 7-stage chain, voice af_heart) on the pinned `tts` directory (kokoro-82m-coreml@2568276).
// FluidAudio resolves `<root>/kokoro-82m-coreml/ANE/…` (chain) and `<root>/kokoro/…` (G2P + lexicon);
// our model store keeps the repo flat under `Models/tts`, so a symlink root maps both names onto it.
import AntiChatEngineProtocol
import FluidAudio
import Foundation

public struct SynthesizedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    /// M3.T10: sample offset of each spoken word's start (from Kokoro's predicted token durations); nil = unknown.
    public var wordStarts: [Int]? = nil

    public init(samples: [Float], sampleRate: Int, wordStarts: [Int]? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.wordStarts = wordStarts
    }

    /// Word starts from a Kokoro chain result: token i (after BOS) is phoneme character i, a space separates words, and
    /// each token lasts `durations[i]` acoustic frames of `samples / frames` samples (FluidAudio documents
    /// `predictedDurations` for exactly this). nil when the token and phoneme counts disagree (out-of-vocab scalars).
    static func wordStarts(phonemes: String, durations: [Int32], frames: Int, samples: Int) -> [Int]? {
        let chars = Array(phonemes)
        guard frames > 0, durations.count == chars.count + 2 else { return nil }
        let perFrame = Double(samples) / Double(frames)
        var frame = Int(durations[0])  // BOS
        var starts: [Int] = []
        var inWord = false
        for (i, c) in chars.enumerated() {
            if c == " " { inWord = false } else if !inWord {
                inWord = true
                starts.append(Int(Double(frame) * perFrame))
            }
            frame += Int(durations[i + 1])
        }
        return starts.isEmpty ? nil : starts
    }
}

public protocol SpeechSynthesizing: Sendable {
    var name: String { get }
    func synthesize(_ text: String) async throws -> SynthesizedAudio
    /// M3.T07: `speed` = the user rate 0.75…1.5 (R-053).
    func synthesize(_ text: String, speed: Float) async throws -> SynthesizedAudio
    /// M3.T08: `voice` = the Settings › Voice id (R-053); nil = the default voice.
    func synthesize(_ text: String, voice: String?, speed: Float) async throws -> SynthesizedAudio
}

extension SpeechSynthesizing {
    public func synthesize(_ text: String, speed: Float) async throws -> SynthesizedAudio { try await synthesize(text) }
    public func synthesize(_ text: String, voice: String?, speed: Float) async throws -> SynthesizedAudio {
        try await synthesize(text, speed: speed)
    }
}

public final class KokoroTTS: SpeechSynthesizing {
    public let name = "kokoro"

    /// Where Kokoro's seven Core ML stages run. FluidAudio's macOS 26 default puts the fp32 noise stage and the iSTFT
    /// tail on the GPU, where they queue behind the chat model's decode during a voice reply (NFR-V1). `voice` keeps
    /// Measured (V1 at T1, 2026-11-08): with the noise stage on the CPU the first chunk took 0.69 s p50 to synthesise
    /// (the CPU is shared with the host's load), against 0.13 s with FluidAudio's routing in M0 — so FluidAudio's
    /// routing ships; the tail cannot leave the GPU on M5 / macOS 26 anyway (#667).
    public enum Placement: String, Sendable {
        /// FluidAudio's default (noise + tail on the GPU on macOS 26).
        case fluidDefault = "default"
        /// Noise on the CPU, tail on the GPU (the tail is tiny; the shipped tail crashed libBNNS on the CPU, #667 and
        /// AT-FA-05 — `KokoroTailRewrite` fixes that).
        case noiseCPU = "noisecpu"
        /// Noise and tail on the CPU: nothing on the GPU (FluidAudio's OS 27 routing, `aneTailCpu`).
        case cpuANE = "cpuane"
        /// Every stage on the CPU: what Core ML runs where it has no GPU and no Neural Engine (the clean VM; probes).
        case cpuOnly = "cpu"

        var units: KokoroAneComputeUnits {
            switch self {
            case .fluidDefault: return .default
            case .noiseCPU:
                return KokoroAneComputeUnits(noise: .cpuOnly, tail: .cpuAndGPU)
            case .cpuANE: return .aneTailCpu
            case .cpuOnly: return .cpuOnly
            }
        }
    }

    /// The shipped placement; `ANTICHAT_KOKORO_PLACEMENT=default|noisecpu|cpuane|cpu` overrides it (perf probes only).
    public static let shippedPlacement = Placement.fluidDefault
    static var placement: KokoroAneComputeUnits {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let p = ProcessInfo.processInfo.environment["ANTICHAT_KOKORO_PLACEMENT"].flatMap(Placement.init(rawValue:)) { return p.units }
        #endif
        return shippedPlacement.units
    }
    private let manager: KokoroAneManager

    /// `ttsDirectory` = the flat `Models/tts` folder; `linkRoot` = a writable folder for the symlinks.
    /// `kokoro-82m-coreml/ANE` is a real folder of symlinks into the (read-only) store plus the English voice packs
    /// converted from `voices/<id>.json` (M3.T08), so FluidAudio finds every voice locally (`ensureVoicePack` reads
    /// `<ANE>/<id>.bin` first) and nothing is ever written into the model store. The tail stage is a real folder too:
    /// its files linked, its `model.mil` rewritten so it never faults on the CPU (`KokoroTailRewrite`, AT-FA-05).
    public static func load(ttsDirectory: URL, linkRoot: URL, placement: Placement? = nil) async throws -> KokoroTTS {
        try await load(ttsDirectory: ttsDirectory, linkRoot: linkRoot, units: placement?.units ?? Self.placement)
    }

    static func load(ttsDirectory: URL, linkRoot: URL, units: KokoroAneComputeUnits) async throws -> KokoroTTS {
        let fm = FileManager.default
        try fm.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        func link(_ at: URL, _ to: URL) throws {
            if (try? fm.destinationOfSymbolicLink(atPath: at.path)) != to.path {
                try? fm.removeItem(at: at)
                try fm.createSymbolicLink(at: at, withDestinationURL: to)
            }
        }
        try link(linkRoot.appendingPathComponent("kokoro"), ttsDirectory)
        let repo = linkRoot.appendingPathComponent("kokoro-82m-coreml")
        if (try? fm.destinationOfSymbolicLink(atPath: repo.path)) != nil { try fm.removeItem(at: repo) }  // older flat link
        let ane = repo.appendingPathComponent("ANE")
        try fm.createDirectory(at: ane, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: ttsDirectory.path)) ?? [] where name != "ANE" {
            try link(repo.appendingPathComponent(name), ttsDirectory.appendingPathComponent(name))
        }
        let storeANE = ttsDirectory.appendingPathComponent("ANE")
        for name in (try? fm.contentsOfDirectory(atPath: storeANE.path)) ?? [] {
            if name == KokoroTailRewrite.bundleName {
                // AT-FA-05: the tail's conv faults in libBNNS on the CPU; served with that op rewritten.
                try KokoroTailRewrite.install(source: storeANE.appendingPathComponent(name), destination: ane.appendingPathComponent(name))
                continue
            }
            try link(ane.appendingPathComponent(name), storeANE.appendingPathComponent(name))
        }
        let voices = ttsDirectory.appendingPathComponent("voices")
        for file in (try? fm.contentsOfDirectory(atPath: voices.path)) ?? [] where file.hasSuffix(".json") {
            let bin = ane.appendingPathComponent(file.replacingOccurrences(of: ".json", with: ".bin"))
            guard !fm.fileExists(atPath: bin.path) || (try? fm.destinationOfSymbolicLink(atPath: bin.path)) != nil else { continue }
            let pack = try KokoroAneVoicePack.load(fromJSON: Data(contentsOf: voices.appendingPathComponent(file)))
            try? fm.removeItem(at: bin)
            try pack.binaryData.write(to: bin, options: .atomic)
        }
        let m = KokoroAneManager(variant: .english, directory: linkRoot, computeUnits: units)
        try await m.initialize()
        return KokoroTTS(manager: m)
    }

    private init(manager: KokoroAneManager) {
        self.manager = manager
    }

    public func synthesize(_ text: String) async throws -> SynthesizedAudio { try await synthesize(text, speed: 1) }

    public func synthesize(_ text: String, speed: Float) async throws -> SynthesizedAudio {
        try await synthesize(text, voice: nil, speed: speed)
    }

    /// M3.T08: `voice` = a `KokoroVoices` id (nil / unknown = af_heart).
    public func synthesize(_ text: String, voice: String?, speed: Float) async throws -> SynthesizedAudio {
        let v = voice.flatMap { id in KokoroVoices.english.contains { $0.id == id } ? id : nil }
        let r = try await manager.synthesizeDetailed(text: text, voice: v, speed: speed)
        return SynthesizedAudio(samples: r.samples, sampleRate: r.sampleRate,
                                wordStarts: SynthesizedAudio.wordStarts(phonemes: r.phonemes, durations: r.predictedDurations,
                                                                        frames: r.acousticFrames, samples: r.samples.count))
    }

    /// M3.T07: the `tts` slot as a scheduler-resident object (`VoiceModelResidency` materializer).
    public static func load(slotDirectory: URL, placement: Placement? = nil) async throws -> KokoroTTS {
        let links = FileManager.default.temporaryDirectory.appendingPathComponent("AntiChat-kokoro", isDirectory: true)
        return try await load(ttsDirectory: slotDirectory, linkRoot: links, placement: placement)
    }
}
