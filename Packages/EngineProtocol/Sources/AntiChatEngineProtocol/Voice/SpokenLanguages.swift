// M3.T08 step 3 (R-053 AC1): the Spoken language list = Parakeet's 25 ∪ WhisperKit's languages (argmax-oss-swift@1bbc57c
// `Models.swift:1341` `Constants.languages`, 100 codes; "jw" is Whisper's spelling of Javanese). Independent of the UI
// language; the picker shows each name in the UI language. `LanguageRouterTests` checks Parakeet's set is a subset.
public enum SpokenLanguages {
    public static let parakeet: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt",
        "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    public static let whisper: [String] = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en",
        "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht", "hu", "hy", "id", "is",
        "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt", "lv", "mg", "mi", "mk", "ml", "mn",
        "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk",
        "sl", "sn", "so", "sq", "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz",
        "vi", "yi", "yo", "yue", "zh",
    ]

    /// Every selectable code (sorted, unique).
    public static let all: [String] = Array(parakeet.union(whisper)).sorted()
}
