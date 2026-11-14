// M3.T08 step 7 (R-053 AC2): Settings › Voice values as the voice paths read them — at the start of each dictation
// (spoken language, microphone) and of each read aloud (voice, speed). Written instantly by the section, so a change
// applies to the next utterance without a restart.
import Defaults
import Foundation

enum VoicePreferences {
    /// nil = Auto-detect (LanguageRouter `auto`).
    static var spokenLanguage: String? {
        let v = Defaults[.voiceSpokenLanguage]
        return v.isEmpty || v == "auto" ? nil : v
    }

    /// nil = the system default input device.
    static var inputDeviceUID: String? {
        let v = Defaults[.voiceInputDevice]
        return v.isEmpty ? nil : v
    }

    static var voiceID: String { Defaults[.voiceID] }
    static var rate: Double { min(1.5, max(0.75, Defaults[.voiceRate])) }
    /// M3.T11 (R-052 AC2): hands-free (default) or push-to-talk, read at each conversation start.
    static var conversationMode: String { Defaults[.voiceMode] }
    /// M3.T12 (R-280 AC3): lower other apps while talking (default on).
    static var duckOthers: Bool { Defaults[.voiceDuckOthers] }
}
