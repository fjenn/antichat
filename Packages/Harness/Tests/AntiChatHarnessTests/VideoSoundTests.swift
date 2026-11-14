// M5.T07 (R-292 AC1): the Sound chip shows on a tier with a sound model in Normal chats only; Evil and silent tiers hide
// it; "Sound on" picks the sound model, otherwise the silent one (Evil video never runs on LTX, K-014).
import Testing
@testable import AntiChatHarness

@Suite struct VideoSoundTests {
    static let t3: [VideoSound.Model] = [.init(key: "vid-5b", capabilities: []), .init(key: "vid-i2v", capabilities: []),
                                         .init(key: "vid-ltx", capabilities: ["audio"])]
    static let t2: [VideoSound.Model] = [.init(key: "vid-5b", capabilities: []), .init(key: "vid-i2v", capabilities: [])]

    @Test func chipOnlyOnSoundTiersInNormalChats() {
        #expect(VideoSound.chipVisible(models: Self.t3, isEvil: false))
        #expect(!VideoSound.chipVisible(models: Self.t3, isEvil: true))
        #expect(!VideoSound.chipVisible(models: Self.t2, isEvil: false))
        #expect(!VideoSound.chipVisible(models: [], isEvil: false))
    }

    @Test func soundOnPicksLTXOnlyWhenAllowed() {
        #expect(VideoSound.model(for: true, models: Self.t3, isEvil: false)?.key == "vid-ltx")
        #expect(VideoSound.model(for: false, models: Self.t3, isEvil: false)?.key == "vid-5b")
        #expect(VideoSound.model(for: true, models: Self.t3, isEvil: true)?.key == "vid-5b", "Evil never uses LTX")
        #expect(VideoSound.model(for: true, models: Self.t2, isEvil: false)?.key == "vid-5b")
    }
}
