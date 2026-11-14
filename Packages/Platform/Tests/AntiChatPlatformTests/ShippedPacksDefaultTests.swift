// Normal builds ship every pack now: Chat always, Voice since M3.T14, Photo since M4.T16, Video since M5.T14. The owner
// try-out preview (`make build-tryout`, compile condition ANTICHAT_TRYOUT_PREVIEW) also turns every pack on, and that
// condition never reaches a release build (tools/ci/tryout-guard.py in make audit).
@testable import AntiChatPlatform
import Testing

struct ShippedPacksDefaultTests {
    @Test func normalBuildsShipEveryPack() {
        #if ANTICHAT_TRYOUT_PREVIEW
        Issue.record("the unit tests must not be built with ANTICHAT_TRYOUT_PREVIEW")
        #else
        #expect(ModelPack.shipped == [.chat, .voice, .photo, .video])
        #expect(ModelPack.shipped == Set(ModelPack.allCases))
        #expect(ModelPack.allCases.allSatisfy { $0.isShipped })
        #endif
    }
}
