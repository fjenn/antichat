// AT-FA-05 regression (`@realModels`, ANTICHAT_VOICE_IT=1): Kokoro with its tail on the CPU — what a Mac whose Core
// ML has no GPU or Neural Engine runs (the 8 GB clean VM). Before `KokoroTailRewrite` the shipped tail's conv faulted
// in libBNNS on these clauses (SIGSEGV, the helper gone); the texts are the AT-FA-05 replies and the prefixes of them
// that faulted on the M5 host with the tail forced to `.cpuOnly` (indices 0, 18, 21, 34, 37, 39, 41, 60, 61 of the
// prefix sweep). A crash ends the test process; the rewritten tail must also match the shipped GPU tail.
//   ANTICHAT_VOICE_IT=1 swift test --filter KokoroTailCPUTests
// Probe form: ANTICHAT_KOKORO_CPU_PROBE=1 [ANTICHAT_KOKORO_PLACEMENT=…] [ANTICHAT_KOKORO_CPU_STAGES=tail,…]
// [ANTICHAT_KOKORO_CPU_PROBE_LOG=…] sweeps every prefix of the replies and logs each text before it is synthesised.
import FluidAudio
import Foundation
import Testing
@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1"))
struct KokoroTailCPUTests {
    static let replies = [
        "I hear you mention a reverend person with a godly minister and leech attending him. How about you?",
        "I understand you're speaking about God's honors.",
        "Oh, that's a bit of a mystery then, but let's give it a try anyway.",
        "Oh no, that sounds like a really dramatic scene, but I am here to help you with anything you need!",
    ]
    /// Clauses whose tail faulted on the CPU before the rewrite.
    static let faulted = [
        "I hear you mention a reverend person with a godly minister and leech attending him. How about you?",
        "I hear you mention a reverend person with a godly minister and leech attending him.",
        "Oh, that's a bit of a",
        "Oh, that's a bit of a mystery then, but",
        "Oh, that's a bit of a mystery then, but let's give",
        "Oh, that's a bit of a mystery then, but let's give it a",
        "Oh no, that sounds like a really dramatic scene, but I am here to help you with",
        "Oh no, that sounds like a really dramatic scene, but I am here to help you with anything",
    ]

    static func load(_ units: KokoroAneComputeUnits, links: String) async throws -> KokoroTTS {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(links, isDirectory: true)
        return try await KokoroTTS.load(ttsDirectory: ParakeetBackendTests.models.appendingPathComponent("tts"),
                                        linkRoot: dir, units: units)
    }

    static func snr(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -.infinity }
        var signal = 0.0, noise = 0.0
        for i in a.indices {
            signal += Double(a[i] * a[i])
            noise += Double((a[i] - b[i]) * (a[i] - b[i]))
        }
        return 10 * log10(signal / max(noise, 1e-30))
    }

    @Test func tailOnTheCPUSynthesisesTheClausesThatFaulted() async throws {
        VoiceEnvironment.lockDown()
        var cpuTail = KokoroAneComputeUnits.default
        cpuTail.tail = .cpuOnly
        let cpu = try await Self.load(cpuTail, links: "AntiChat-kokoro-tailcpu-test")
        let shipped = try await Self.load(.default, links: "AntiChat-kokoro-default-test")
        for text in Self.faulted + Self.replies {
            let a = try await cpu.synthesize(text)
            let b = try await shipped.synthesize(text)
            #expect(!a.samples.isEmpty, "\(text)")
            // Same stages 1–6 (same placement), so the tails must agree: fp32 on BNNS vs fp32 on the GPU.
            #expect(Self.snr(b.samples, a.samples) > 60, "\(text)")
        }
    }

    /// The clean VM's routing: no GPU, no Neural Engine — every stage on the CPU.
    @Test func everyStageOnTheCPU() async throws {
        VoiceEnvironment.lockDown()
        let tts = try await Self.load(.cpuOnly, links: "AntiChat-kokoro-allcpu-test")
        for text in Self.faulted + Self.replies {
            #expect(try await !tts.synthesize(text).samples.isEmpty, "\(text)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_KOKORO_CPU_PROBE"] == "1"))
    func sweep() async throws {
        VoiceEnvironment.lockDown()
        let env = ProcessInfo.processInfo.environment
        let placement = env["ANTICHAT_KOKORO_PLACEMENT"].flatMap(KokoroTTS.Placement.init(rawValue:)) ?? .cpuOnly
        let stages = env["ANTICHAT_KOKORO_CPU_STAGES"] ?? ""
        var units = placement.units
        for stage in stages.split(separator: ",") {
            switch stage {
            case "albert": units.albert = .cpuOnly
            case "postAlbert": units.postAlbert = .cpuOnly
            case "alignment": units.alignment = .cpuOnly
            case "prosody": units.prosody = .cpuOnly
            case "noise": units.noise = .cpuOnly
            case "vocoder": units.vocoder = .cpuOnly
            case "tail": units.tail = .cpuOnly
            default: break
            }
        }
        let log = env["ANTICHAT_KOKORO_CPU_PROBE_LOG"] ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-cpu-probe.log").path
        FileManager.default.createFile(atPath: log, contents: nil)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        let tts = try await Self.load(units, links: "AntiChat-kokoro-probe")
        var texts = Self.replies
        for r in Self.replies {
            let w = r.split(separator: " ")
            for n in 1...w.count { texts.append(w.prefix(n).joined(separator: " ")) }
        }
        var n = 0
        for t in texts {
            h.write(Data("\(placement.rawValue)+\(stages)\t\(t)\n".utf8))
            try? h.synchronize()
            let a = try await tts.synthesize(t)
            n += a.samples.isEmpty ? 0 : 1
        }
        h.write(Data("done \(n)/\(texts.count)\n".utf8))
        #expect(n == texts.count)
    }
}
