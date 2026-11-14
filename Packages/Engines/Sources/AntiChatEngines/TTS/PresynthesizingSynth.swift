// NFR-V1 (A-M3-T09c): the first spoken chunk of a speculative reply is synthesised while the end of the turn is
// still being decided. The session's Kokoro synthesiser is wrapped: `presynthesize(text, voice, speed)` starts the
// synthesis of one chunk and keeps the result; a later `synthesize` of the **same text, voice and speed** (the
// adopted reply's first chunk: same chunker, same text) takes it instead of synthesising again. Nothing is played
// here: audio reaches the output only through the reply's own `KokoroBackend.speak`, for a chunk of the reply itself,
// so the audio of a discarded speculation is never heard (a different text never matches; the entry is replaced by
// the next speculation and used at most once).
import Foundation
import Synchronization

public final class PresynthesizingSynth: SpeechSynthesizing, @unchecked Sendable {  // state behind a Mutex
    public var name: String { inner.name }
    private let inner: any SpeechSynthesizing

    private struct Key: Hashable {
        var text: String
        var voice: String?
        var speed: Float
    }

    private let entry = Mutex<(key: Key, task: Task<SynthesizedAudio?, Never>)?>(nil)
    /// Uses of a presynthesised chunk (tests, probes).
    public let hits = Mutex(0)

    public init(_ inner: any SpeechSynthesizing) { self.inner = inner }

    /// Starts synthesising `text` (one chunk) ahead of time; replaces an earlier entry with another key.
    public func presynthesize(_ text: String, voice: String?, speed: Float) {
        let key = Key(text: text, voice: voice, speed: speed)
        let inner = inner
        let old: Task<SynthesizedAudio?, Never>? = entry.withLock { e in
            if e?.key == key { return nil }
            let previous = e?.task
            e = (key, Task(priority: .userInitiated) { try? await inner.synthesize(text, voice: voice, speed: speed) })
            return previous
        }
        old?.cancel()
    }

    /// Drops the entry (not used by any reply).
    public func drop() {
        let old = entry.withLock { e in
            defer { e = nil }
            return e?.task
        }
        old?.cancel()
    }

    public func synthesize(_ text: String) async throws -> SynthesizedAudio {
        try await synthesize(text, voice: nil, speed: 1)
    }

    public func synthesize(_ text: String, speed: Float) async throws -> SynthesizedAudio {
        try await synthesize(text, voice: nil, speed: speed)
    }

    public func synthesize(_ text: String, voice: String?, speed: Float) async throws -> SynthesizedAudio {
        let key = Key(text: text, voice: voice, speed: speed)
        let ready: Task<SynthesizedAudio?, Never>? = entry.withLock { e in
            guard let current = e, current.key == key else { return nil }
            e = nil  // used at most once
            return current.task
        }
        if let ready, let audio = await ready.value, !audio.samples.isEmpty {
            hits.withLock { $0 += 1 }
            return audio
        }
        return try await inner.synthesize(text, voice: voice, speed: speed)
    }
}
