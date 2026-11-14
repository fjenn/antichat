// M4.T16 round 2: `-FakePackState photo=…` reaches the install-card path (it was honoured for voice only, so the
// scripted image journey hit "coming soon" before create_image could run).
import AntiChatHarness
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct FakePackStateTests {
    @Test func fakeStatesMapToCardAvailability() {
        #expect(CapabilitiesPackInstaller.fakeAvailability("ready") == .installed)
        #expect(CapabilitiesPackInstaller.fakeAvailability("downloading") == .installing(percent: 42))
        if case .installable(let b, _)? = CapabilitiesPackInstaller.fakeAvailability("absent") { #expect(b > 0) } else { Issue.record("absent") }
        #expect(CapabilitiesPackInstaller.fakeAvailability(nil) == nil && CapabilitiesPackInstaller.fakeAvailability("x") == nil)
    }
}
