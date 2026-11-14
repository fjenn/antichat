// M3.T08 (R-053 AC1: ≥ 6 voices): the Kokoro-82M English voices the Voice pack carries (`tts` slot: `ANE/af_heart.bin`
// + `voices/<id>.json`, catalog/models.yaml). Shared by the helper (KokoroTTS) and Settings › Voice (the picker).
// Names are Kokoro's own voice names; the accent is the voice's (en-US "a…", en-GB "b…"). The order is the picker's.
public enum KokoroVoices {
    public struct Voice: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        /// BCP-47 accent of the voice.
        public var language: String
    }

    public static let defaultID = "af_heart"

    public static let english: [Voice] = [
        .init(id: "af_heart", name: "Heart", language: "en-US"),
        .init(id: "af_bella", name: "Bella", language: "en-US"),
        .init(id: "af_nicole", name: "Nicole", language: "en-US"),
        .init(id: "af_sarah", name: "Sarah", language: "en-US"),
        .init(id: "am_adam", name: "Adam", language: "en-US"),
        .init(id: "am_michael", name: "Michael", language: "en-US"),
        .init(id: "bf_emma", name: "Emma", language: "en-GB"),
        .init(id: "bm_george", name: "George", language: "en-GB"),
    ]
}
