// M3.T05 (AT-284 routing leg; R-284): the routing table and the auto re-run, with test doubles for both recognisers.
//   make test-unit FILTER=LanguageRouterTests
import AntiChatEngineProtocol
import Foundation
import Synchronization
import Testing

@testable import AntiChatEngines

/// A WhisperKit stand-in: detects `detected`, transcribes `"whisper:<language>"`.
final class FakeWhisper: MultilingualRecognizer, @unchecked Sendable {
    let detected: String
    let calls = Mutex<[String]>([])
    init(detected: String = "ja") { self.detected = detected }
    func transcribe(_ samples: [Float], language: String?) async throws -> WhisperKitModel.Result {
        calls.withLock { $0.append("transcribe:\(language ?? "nil")") }
        return WhisperKitModel.Result(text: "whisper:\(language ?? "auto")", language: language ?? detected, segments: [])
    }
    func detectLanguage(_ samples: [Float]) async throws -> (language: String, probability: Float) {
        calls.withLock { $0.append("detect") }
        return (detected, 0.97)
    }
}

struct LanguageRouterTests {
    @Test(arguments: Array(ParakeetBackend.languageCodes))
    func parakeetLanguagesStayOnParakeet(lang: String) {
        #expect(LanguageRouter.route(setting: lang) == .parakeet)
    }

    @Test(arguments: ["ja", "zh", "ar", "hi", "ko", "th", "zh-Hans", "ja-JP"])
    func otherLanguagesGoToWhisperKit(setting: String) {
        let base = String(setting.prefix(2))
        #expect(LanguageRouter.route(setting: setting) == .whisper(language: base))
    }

    @Test func autoIsAuto() {
        #expect(LanguageRouter.route(setting: nil) == .auto)
        #expect(LanguageRouter.route(setting: "auto") == .auto)
        #expect(LanguageRouter.route(setting: "de-CH") == .parakeet)
    }

    @Test func autoDecision() {
        let en: Set<String> = ["en"]
        #expect(LanguageRouter.keepsParakeet("The quick brown fox jumps over the lazy dog near the river bank.", userLanguages: en))
        #expect(!LanguageRouter.keepsParakeet("Der schnelle braune Fuchs springt über den faulen Hund am Flussufer.", userLanguages: en),
                "not the user's language: the audio decides")
        #expect(LanguageRouter.keepsParakeet("Der schnelle braune Fuchs springt über den faulen Hund am Flussufer.", userLanguages: ["en", "de"]))
        // Parakeet's Latin-script rendering of Japanese speech (AT-284 run 1) reads as Croatian: never trusted blindly.
        #expect(!LanguageRouter.keepsParakeet("Hongkongno Čihesen egaite tačina labo virugunga Viktoria Habano Mizno Sondainotte", userLanguages: en))
        #expect(!LanguageRouter.keepsParakeet("今日はとても良い天気ですね、散歩に行きましょう。", userLanguages: en))
        #expect(!LanguageRouter.keepsParakeet("", userLanguages: en))
        // AT-284: Parakeet's garbage on Chinese speech reads as confident English; its own confidence says otherwise.
        #expect(!LanguageRouter.keepsParakeet("Dang so young to jura children women today", confidence: 0.48, userLanguages: en))
        #expect(LanguageRouter.keepsParakeet("The quick brown fox jumps over the lazy dog near the river bank.", confidence: 0.95,
                                             userLanguages: en))
        #expect(LanguageRouter.needsWhisper(detected: "ja") && !LanguageRouter.needsWhisper(detected: "de"))
    }

    static func run(_ backend: RoutedBackend, seconds: Double = 1) async throws -> FinalTranscript {
        _ = try await backend.start(locale: nil)
        backend.append(samples: [Float](repeating: 0.01, count: Int(seconds * 16_000)))
        return try await backend.finish()
    }

    @Test func autoWithAJapaneseParakeetTranscriptReRunsInWhisperKit() async throws {
        let whisper = FakeWhisper(detected: "ja")
        let leased = Mutex(0)
        let b = RoutedBackend(parakeet: FakeBackend(finalText: "今日はとても良い天気ですね、散歩に行きましょう。"),
                              whisper: { leased.withLock { $0 += 1 }; return (whisper, {}) }, setting: "auto")
        let f = try await Self.run(b)
        #expect(f.engine == .whisperkit && f.language == "ja" && f.text == "whisper:ja")
        #expect(whisper.calls.withLock { $0 } == ["detect", "transcribe:ja"])
        #expect(leased.withLock { $0 } == 1, "stt-multi leased on demand")
    }

    @Test func autoWithEnglishStaysOnParakeetWithoutLeasingWhisperKit() async throws {
        let leased = Mutex(0)
        let b = RoutedBackend(parakeet: FakeBackend(finalText: "The quick brown fox jumps over the lazy dog near the river bank."),
                              whisper: { leased.withLock { $0 += 1 }; return (FakeWhisper(), {}) }, setting: nil)
        let f = try await Self.run(b)
        #expect(f.engine == .parakeet && f.language == "en")
        #expect(leased.withLock { $0 } == (LanguageRouter.userLanguages.contains("en") ? 0 : 1), "the user's own language: no audio check")
    }

    @Test func autoKeepsParakeetWhenTheAudioIsAParakeetLanguage() async throws {
        let whisper = FakeWhisper(detected: "de")
        let b = RoutedBackend(parakeet: FakeBackend(finalText: "Der schnelle braune Fuchs."), whisper: { (whisper, {}) }, setting: nil)
        let f = try await Self.run(b)
        #expect(f.engine == .parakeet && f.language == "de")
        #expect(whisper.calls.withLock { $0 } == ["detect"])
    }

    @Test func fixedNonParakeetLanguageRunsWhisperKitWithIt() async throws {
        let whisper = FakeWhisper(detected: "en")
        let b = RoutedBackend(parakeet: FakeBackend(), whisper: { (whisper, {}) }, setting: "ar")
        let f = try await Self.run(b)
        #expect(f.engine == .whisperkit && f.language == "ar" && f.text == "whisper:ar")
        #expect(!whisper.calls.withLock { $0 }.contains("detect"), "a fixed language is never detected")
    }
}
