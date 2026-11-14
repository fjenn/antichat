// Lifetime guard for AVSpeechSynthesizer (fix for the AntiChatEnginesTests SIGSEGV/SIGABRT of merge round 5).
// macOS's TextToSpeech framework delivers an AVSpeechSynthesizer's buffer and delegate callbacks as blocks on the main
// queue that do NOT retain the synthesizer. When the owner (SystemTTS / SystemVoiceBackend) is released right after
// its last callback, the synthesizer is deallocated while such blocks are still queued, and the next one crashes in
// `objc_retain` inside TextToSpeech (caught under lldb: EXC_BAD_ACCESS, main queue, TextToSpeech frames only). Owners
// therefore never let their synthesizer die with them: `retire` stops it, detaches the delegate and keeps it alive
// for `grace` on the main queue, after every block TextToSpeech had queued for it.
@preconcurrency import AVFoundation
import Foundation

enum SpeechSynthesizerKeeper {
    static let grace: DispatchTimeInterval = .seconds(10)

    static func retire(_ synth: AVSpeechSynthesizer) {
        let box = Box(synth)
        DispatchQueue.main.async {
            box.synth.delegate = nil
            if box.synth.isSpeaking { box.synth.stopSpeaking(at: .immediate) }
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) { _ = box }  // the last strong reference
        }
    }

    private final class Box: @unchecked Sendable {
        let synth: AVSpeechSynthesizer
        init(_ s: AVSpeechSynthesizer) { synth = s }
    }
}
