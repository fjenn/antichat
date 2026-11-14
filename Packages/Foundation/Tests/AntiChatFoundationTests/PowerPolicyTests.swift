// AT-207 (R-207 AC1/AC2; M2.T14 step 2): Auto switches to Battery saver on battery < 20 % or in Low Power Mode;
// Maximum never switches; Battery saver always applies; FeatureFlag.powerPolicy off = Maximum (no automatic change).
// Battery saver effects: keep-alive 5 min (lowPower), image/video one step lower, 30 Hz render cadence.
import AntiChatFoundation
import Testing

@Suite struct PowerPolicyTests {
    @Test func autoSwitchesBelow20PercentOrInLowPower() {
        #expect(PowerPolicy.effective(.auto, onAC: true, batteryPercent: 5, lowPowerMode: false) == .maximum, "on AC")
        #expect(PowerPolicy.effective(.auto, onAC: false, batteryPercent: 20, lowPowerMode: false) == .maximum)
        #expect(PowerPolicy.effective(.auto, onAC: false, batteryPercent: 19, lowPowerMode: false) == .batterySaver)
        #expect(PowerPolicy.effective(.auto, onAC: false, batteryPercent: 15, lowPowerMode: false) == .batterySaver)
        #expect(PowerPolicy.effective(.auto, onAC: true, batteryPercent: 90, lowPowerMode: true) == .batterySaver)
        #expect(PowerPolicy.effective(.auto, onAC: true, batteryPercent: nil, lowPowerMode: false) == .maximum, "desktop Mac")
    }

    @Test func maximumAndSaverAreFixed() {
        #expect(PowerPolicy.effective(.maximum, onAC: false, batteryPercent: 3, lowPowerMode: true) == .maximum)
        #expect(PowerPolicy.effective(.batterySaver, onAC: true, batteryPercent: 100, lowPowerMode: false) == .batterySaver)
    }

    @Test func flagOffMeansNoAutomaticChange() {
        #expect(PowerPolicy.effective(.auto, onAC: false, batteryPercent: 5, lowPowerMode: true, enabled: false) == .maximum)
    }

    @Test func batterySaverEffects() {
        let e = PowerPolicy.effects(.batterySaver)
        #expect(e.lowPower && e.mediaStepDown && e.renderHz == 30)
        #expect(PowerPolicy.saverKeepAliveSeconds == 300)
        let m = PowerPolicy.effects(.maximum)
        #expect(!m.lowPower && !m.mediaStepDown)
    }

    @Test func pressureLevelNames() {
        #expect(PressureLevel(name: "warn") == .warning && PressureLevel(name: "critical") == .critical)
        #expect(PressureLevel.warning < .critical && PressureLevel(name: "x") == nil)
    }
}
