// AVSpeechSynthesizer fallback (D-010; K-NEW-MOD-8, K-NEW-ENG-9): zero download, used when Kokoro does not
// fit the tier budget or fails (crash-prone macOS 26.4–26.5 builds). Renders to PCM buffers with
// `write(_:toBufferCallback:)`, so the same playback path schedules the result.
@preconcurrency import AVFoundation
import Foundation

public final class SystemTTS: SpeechSynthesizing, @unchecked Sendable {
    public let name = "system"
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private let voice: AVSpeechSynthesisVoice?

    public init(language: String = "en-US") {
        voice = AVSpeechSynthesisVoice(language: language)
    }

    deinit { SpeechSynthesizerKeeper.retire(synth) }

    public func synthesize(_ text: String) async throws -> SynthesizedAudio {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        final class Acc: @unchecked Sendable {
            var samples: [Float] = []
            var rate = 22_050
            var done = false
        }
        let acc = Acc()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SynthesizedAudio, Error>) in
            lock.lock()
            synth.write(utterance) { buffer in
                guard !acc.done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    acc.done = true
                    cont.resume(returning: SynthesizedAudio(samples: acc.samples, sampleRate: acc.rate))
                    return
                }
                acc.rate = Int(pcm.format.sampleRate)
                let n = Int(pcm.frameLength)
                if let f = pcm.floatChannelData {
                    acc.samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
                } else if let i = pcm.int16ChannelData {
                    acc.samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32768 })
                }
            }
            lock.unlock()
        }
    }
}
