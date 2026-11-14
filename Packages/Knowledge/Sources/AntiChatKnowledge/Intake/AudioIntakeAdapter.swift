// M3.T06 step 1 (R-056; D-026 note 2: closes the M6 audio leg): audio attachments. Accepted UTIs: public.wav,
// public.mp3, public.mpeg-4-audio (m4a), public.aac-audio, org.xiph.flac (TypeSniffer's audio kinds, by magic); a file
// over 512 MB or 3 h is refused with `upload.tooLarge` ("512 MB or 3 h") before any transcription; any other audio is
// `upload.unsupported` (TypeSniffer never sniffs it as audio). Transcription itself runs in the helper (contract 1):
// `AudioTranscribing` is the app's client of the `TranscribeFile` message; intake shows its real % on the tile
// (`status.transcribing`) and keeps the timestamped transcript (`[hh:mm:ss] text` lines) as the attachment's extracted
// text, so the chat model reads it like any document ("summarise this").
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The helper's file transcription as intake sees it (the app wires `FileTranscriptionClient`).
public protocol AudioTranscribing: Sendable {
    /// False without a verified Voice pack: the tile keeps `tile.transcriptPending` (the M6 behaviour).
    func isAvailable() async -> Bool
    /// `progress` 0…100, monotonic. Returns the timestamped transcript (empty when the file holds no speech).
    func transcribe(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscript
}

public struct AudioTranscript: Sendable, Equatable {
    /// `[hh:mm:ss] text` per segment, one per line.
    public var text: String
    public var language: String
    public var engine: String

    public init(text: String, language: String, engine: String) {
        self.text = text
        self.language = language
        self.engine = engine
    }
}

public enum AudioIntakeAdapter {
    public static let maxDuration: TimeInterval = 3 * 3600
    public static let utis: Set<String> = ["public.wav", "public.mp3", "public.mpeg-4-audio", "public.aac-audio", "org.xiph.flac"]

    /// The UTI of an audio kind (nil for anything else).
    public static func uti(_ kind: AttachmentKind) -> String? {
        switch kind {
        case .wav: "public.wav"
        case .mp3: "public.mp3"
        case .m4a: "public.mpeg-4-audio"
        case .aac: "public.aac-audio"
        case .flac: "org.xiph.flac"
        default: nil
        }
    }

    public static func accepts(uti: String) -> Bool { utis.contains(uti) }

    /// The file's duration in seconds (nil when Core Audio cannot open it).
    public static func duration(_ url: URL) -> TimeInterval? {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// Step 1 limits: true when the file is over 512 MB or 3 h.
    public static func isTooLarge(size: Int64, duration: TimeInterval?) -> Bool {
        size > AttachmentLimits.maxFileBytes || (duration ?? 0) > maxDuration
    }

    /// `[hh:mm:ss]` of a time in seconds.
    public static func stamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "[%02d:%02d:%02d]", s / 3600, s / 60 % 60, s % 60)
    }

    /// `m:ss` / `h:mm:ss` for the ready tile (`tile.audio` `{duration}`).
    public static func durationLabel(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
