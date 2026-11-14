// M3.T06 (R-056, AT-056 AC1 `AudioIntakeAdapterTests`): audio UTIs (WAV, MP3, M4A, AAC, FLAC sniffed by magic; others
// refused), the 512 MB / 3 h limit before any transcription, and the intake leg: an audio file is transcribed through
// `AudioTranscribing` with a monotonic real % on the tile (`transcribing`), then ready with the timestamped transcript
// as its extracted text; without a Voice pack the tile stays `tile.transcriptPending` (the M6 behaviour).
//   make test-unit FILTER=AudioIntakeAdapterTests
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatKnowledge

final class FakeTranscriber: AudioTranscribing, @unchecked Sendable {
    let available: Bool
    let lock = NSLock()
    var urls: [URL] = []
    init(available: Bool = true) { self.available = available }
    func isAvailable() async -> Bool { available }
    func transcribe(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscript {
        lock.withLock { urls.append(url) }
        for p in [0.0, 12.5, 50, 87.5, 100] { progress(p) }
        return AudioTranscript(text: "[00:00:00] Hello there.\n[00:00:04] Second line.", language: "en", engine: "parakeet")
    }
}

@Suite struct AudioIntakeAdapterTests {
    static let formats = ["wav", "mp3", "m4a", "aac", "flac"]

    @Test func fiveAudioFormatsAreAcceptedByMagic() throws {
        for ext in Self.formats {
            let url = IntakeFixtures.url("audio/formats/clip.\(ext)")
            guard FileManager.default.fileExists(atPath: url.path) else { Issue.record("fixture clip.\(ext) missing"); continue }
            let s = try TypeSniffer.sniff(url)
            #expect(s.kind.isAudio, "\(ext): \(s.kind)")
            #expect(AudioIntakeAdapter.uti(s.kind).map(AudioIntakeAdapter.accepts(uti:)) == true, "\(ext)")
            let item = AttachmentIntake.admit([url]).items[0]
            #expect(item.state == .reading(nil), "\(ext): \(item.state)")
            #expect(abs((item.duration ?? 0) - 120.75) < 1.5, "\(ext): duration \(item.duration ?? -1)")
        }
        #expect(!AudioIntakeAdapter.accepts(uti: "public.aiff-audio"))
        #expect(!AudioIntakeAdapter.accepts(uti: "com.microsoft.waveform-audio-ogg"))
    }

    @Test func overThreeHoursOrFiveHundredTwelveMegabytesIsTooLarge() throws {
        #expect(AudioIntakeAdapter.isTooLarge(size: 10, duration: 3 * 3600 + 1))
        #expect(!AudioIntakeAdapter.isTooLarge(size: 10, duration: 3 * 3600))
        #expect(AudioIntakeAdapter.isTooLarge(size: AttachmentLimits.maxFileBytes + 1, duration: 60))
        // A real WAV header that says 3 h 0 min 10 s (1 kHz, 8-bit; sparse data: ~10.8 MB, nothing written).
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("long.wav")
        let frames = UInt32((3 * 3600 + 10) * 1000)
        try Self.wavHeader(sampleRate: 1000, frames: frames).write(to: url)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 44 + UInt64(frames))
        try h.close()
        let item = AttachmentIntake.admit([url]).items[0]
        #expect(item.kind.isAudio)
        #expect(item.state == .tooLarge(size: 44 + Int64(frames)), "\(item.state) duration \(item.duration ?? -1)")
    }

    @Test func intakeTranscribesWithARealPercentThenKeepsTheTranscript() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let t = FakeTranscriber()
        let intake = AttachmentIntake(database: db, mediaRoot: dir.appendingPathComponent("Media", isDirectory: true),
                                      incognito: false, transcriber: t)
        let item = AttachmentIntake.admit([IntakeFixtures.url("docs/formats-8/memo.m4a")]).items[0]
        let seen = UpdateLog()
        let done = await intake.ingest(item) { seen.add($0.state) }
        #expect(done.state == .ready)
        #expect(done.document?.markdown.hasPrefix("[00:00:00] Hello there.") == true)
        #expect(done.document?.transcriptionPending == false)
        #expect(t.urls == [done.storedURL!], "the stored copy is transcribed")
        let pct = seen.states.compactMap { s -> Double? in if case .transcribing(let p) = s { p } else { nil } }
        #expect(pct.first == 0 && pct.last == 100 && zip(pct, pct.dropFirst()).allSatisfy { $0 <= $1 }, "\(pct)")
        #expect(!IntakeState.transcribing(percent: 50).isSendable)
        // The prompt layer reads the transcript as the attachment's extracted text.
        let sha = done.storedURL!.deletingPathExtension().lastPathComponent
        #expect(await intake.markdown(sha256: sha)?.contains("Second line.") == true)
    }

    @Test func withoutTheVoicePackTheTranscriptStaysPending() async throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let t = FakeTranscriber(available: false)
        let intake = AttachmentIntake(database: db, mediaRoot: dir.appendingPathComponent("Media", isDirectory: true),
                                      incognito: false, transcriber: t)
        let done = await intake.ingest(AttachmentIntake.admit([IntakeFixtures.url("docs/formats-8/memo.m4a")]).items[0])
        #expect(done.state == .ready && done.document?.transcriptionPending == true && t.urls.isEmpty)
    }

    @Test func stampsAndDurations() {
        #expect(AudioIntakeAdapter.stamp(3725.9) == "[01:02:05]")
        #expect(AudioIntakeAdapter.durationLabel(120.75) == "2:01")
        #expect(AudioIntakeAdapter.durationLabel(3 * 3600) == "3:00:00")
    }

    static func wavHeader(sampleRate: UInt32, frames: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate); u16(1); u16(8)
        d.append(contentsOf: Array("data".utf8)); u32(frames)
        return d
    }
}
