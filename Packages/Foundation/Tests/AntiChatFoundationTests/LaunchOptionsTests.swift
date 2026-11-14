// M1.T02: every debug launch option of docs/prd/M1.md convention 10 parses (and malformed values are reported).
import Foundation
import Testing
@testable import AntiChatFoundation

@Suite struct LaunchOptionsTests {
    @Test func emptyArgumentsGiveDefaults() {
        let o = LaunchOptions.parse(["/path/AntiChat"])
        #expect(o.isEmpty)
        #expect(o.errors.isEmpty)
    }

    @Test func everyOptionParses() {
        let o = LaunchOptions.parse([
            "/path/AntiChat",
            "-UseScriptedEngine", "fixtures/scripts/s2.jsonl",
            "-UseScriptedTools", "YES",
            "-ANTICHAT_DEV_CONTAINER", "/tmp/antichat-uitest-1",
            "-OfflineOnly", "YES",
            "-FakeHardware", "T1",
            "-FixedClock", "2026-10-30T12:00:00Z",
            "-FakeEvilEnabled", "YES",
            "-FakeVoiceInstalled", "true",
            "-FakeInstalledPacks", "chat,voice, photo",
            "-FakeDisabledPacks", "video",
            "-FakeWebSearchEnabled", "1",
            "-FakeConnectionsEnabled", "YES",
            "-FakeContextWindow", "8192",
            "-RendererCPUScale", "0.25",
            "-PrefillThrottleTokPerSec", "900",
            "-sendWithCommandEnter", "YES",
            "-plainTextComposer", "NO",
            "-showContextUsage", "YES",
            "-ComposerHarness", "project+mode", "-ArtifactsHarness", "/tmp/artifacts",
            "-UIProbe", "/tmp/probe",
            "-PaletteProbe", "/tmp/palette-probe",
            "-RendererProbe", "/tmp/renderer",
            "-ContextProbe", "/tmp/context",
            "-SettingsProbe", "/tmp/settings",
            "-AppearanceProbe", "/tmp/appearance", "-A11yProbe", "/tmp/a11y",
            "-ShortcutsProbe", "/tmp/shortcuts",
            "-DefaultsSuite", "com.antichat.test", "-FreshDefaultsSuite", "YES",
            "-TurnProbe", "/tmp/turn",
            "-IncognitoProbe", "/tmp/incognito",
            "-MenusProbe", "/tmp/menus",
            "-UseScriptedVoice", "/tmp/voice/scripts/dictation-anatomy.jsonl",
            "-FakePackState", "voice=Downloading",
            "-showModelInfo", "YES",
            "-DraftProbe", "/tmp/draft",
            "-ModelInfoProbe", "/tmp/modelinfo",
        ])
        #expect(o.errors.isEmpty)
        #expect(o.scriptedEngineScript == "fixtures/scripts/s2.jsonl")
        #expect(o.useScriptedTools)
        #expect(o.devContainer == "/tmp/antichat-uitest-1")
        #expect(o.offlineOnly)
        #expect(o.fakeHardware == .T1)
        #expect(o.fixedClock == Date(timeIntervalSince1970: 1_793_361_600))
        #expect(o.fakeEvilEnabled)
        #expect(o.fakeVoiceInstalled)
        #expect(o.fakeInstalledPacks == ["chat", "voice", "photo"])
        #expect(o.fakeDisabledPacks == ["video"])
        #expect(o.fakeWebSearchEnabled)
        #expect(o.fakeConnectionsEnabled)
        #expect(o.fakeContextWindow == 8192)
        #expect(o.rendererCPUScale == 0.25)
        #expect(o.prefillThrottleTokPerSec == 900)
        #expect(o.sendWithCommandEnter == true)
        #expect(o.plainTextComposer == false)
        #expect(o.showContextUsage == true)
        #expect(o.showModelInfo == true)
        #expect(o.draftProbe == "/tmp/draft")
        #expect(o.modelInfoProbe == "/tmp/modelinfo")
        #expect(o.composerHarness == "project+mode")
        #expect(o.artifactsHarness == "/tmp/artifacts")
        #expect(o.uiProbe == "/tmp/probe")
        #expect(o.paletteProbe == "/tmp/palette-probe")
        #expect(o.rendererProbe == "/tmp/renderer")
        #expect(o.contextProbe == "/tmp/context")
        #expect(o.settingsProbe == "/tmp/settings")
        #expect(o.appearanceProbe == "/tmp/appearance")
        #expect(o.a11yProbe == "/tmp/a11y")
        #expect(o.shortcutsProbe == "/tmp/shortcuts")
        #expect(o.defaultsSuite == "com.antichat.test")
        #expect(o.freshDefaultsSuite)
        #expect(o.turnProbe == "/tmp/turn")
        #expect(o.incognitoProbe == "/tmp/incognito")
        #expect(o.menusProbe == "/tmp/menus")
        #expect(o.scriptedVoiceScript == "/tmp/voice/scripts/dictation-anatomy.jsonl")
        #expect(o.fakePackStates == ["voice": "downloading"])
        #expect(LaunchOptions.parse(["-FakePackState", "voice=maybe"]).errors.count == 1)
    }

    @Test func everyKeyIsCoveredByTheFullParse() {
        // Guards the registry: a new Key without a parse branch shows up here as an unset field.
        #expect(LaunchOptions.Key.allCases.count == 72)  // + M9.T06 SoakProbe; + fix/test-plist-hygiene FreshDefaultsSuite; + M10.T06/T07 OpenURLSpy, SimulateUpdatedFrom; + M10.T09 FinalAcceptanceProbe; + M3.T12 FakeAEC, FakeAudioRoute; + M9.T01 A11yProbe; + M8.T12–T13 NotificationSpy, MacIntegrationProbe, QuickPanelHotkeyHook; + M7.T11 RelayURL; + M5.T03 UseScriptedVideoEngine; + M3.T08 FakeAudioDevices; + M7.T07 OAuthHeadless; + M4.T04 UseScriptedImageEngine; + M7.T06 DumpPrompts, ScriptedMCP; + M7.T03 SearchProbe, ScriptedWebSearch; + M3.T04 FakePackState; + M3.T03 UseScriptedVoice; + M3.T02 FakePermission; + M7.T01 SearchBlockEngine; + M4.T10 ArtifactsHarness; + M2.T26 VisualQAProbe; + M2.T20 OnboardingProbe; + M2.T18 SkipOnboarding, ResetOnboarding; + M2.T17 FakeLAContext; + M2.T14 FakeThermal, FakePressure + M2.T09 FakePower, DownloadHost; + M2.T05 CatalogURL; M2.T01 FakeFreeDiskGB, PrintHardwareProfile; M2.T03 FakeNetwork, TestProxy  // + M1.T22 SettingsProbe, DefaultsSuite; M1.T23 AppearanceProbe; M1.T24 ShortcutsProbe
    }

    @Test func fakeAudioOptionsParse() {  // M3.T12
        let o = LaunchOptions.parse(["-FakeAEC", "unavailable", "-FakeAudioRoute", "Headphones"])
        #expect(o.fakeAudio == "aec=unavailable,route=headphones")
        #expect(LaunchOptions.parse([]).fakeAudio == nil)
    }

    @Test func mcpOptionsParse() {  // M7.T06
        let o = LaunchOptions.parse(["-DumpPrompts", "/tmp/prompts", "-ScriptedMCP", "/tmp/s.jsonl", "-OAuthHeadless", "YES"])
        #expect(o.oauthHeadless)
        #expect(o.dumpPrompts == "/tmp/prompts" && o.scriptedMCP == "/tmp/s.jsonl")
    }

    @Test func searchProbeOptionsParse() {  // M7.T03
        let o = LaunchOptions.parse(["-SearchProbe", "/tmp/search", "-ScriptedWebSearch", "YES"])
        #expect(o.searchProbe == "/tmp/search" && o.scriptedWebSearch)
        #expect(!LaunchOptions.parse([]).scriptedWebSearch)
    }

    @Test func searchBlockEngineParses() {  // M7.T01 (AT-248 c3)
        #expect(LaunchOptions.parse(["-SearchBlockEngine", "DuckDuckGo, brave"]).searchBlockEngines == ["duckduckgo", "brave"])
        #expect(LaunchOptions.parse([]).searchBlockEngines.isEmpty)
    }

    @Test func automationRunIsAnyProbeHarnessOrDevContainer() {  // background test runs (BackgroundRun)
        #expect(!LaunchOptions.parse([]).isAutomationRun)
        #expect(!LaunchOptions.parse(["-OfflineOnly", "YES", "-FakeHardware", "T1"]).isAutomationRun)
        #expect(LaunchOptions.parse(["-UIProbe", "/tmp/p"]).isAutomationRun)
        #expect(LaunchOptions.parse(["-ArtifactsHarness", "/tmp/a"]).isAutomationRun)
        #expect(LaunchOptions.parse(["-SoakProbe", "/tmp/s"]).isAutomationRun)  // M9.T06
        #expect(LaunchOptions.parse(["-ANTICHAT_DEV_CONTAINER", "/tmp/c"]).isAutomationRun)
    }

    @Test func visualQAProbeParses() {  // M2.T26
        #expect(LaunchOptions.parse(["-VisualQAProbe", "/tmp/vq"]).visualQAProbe == "/tmp/vq")
    }

    @Test func onboardingProbeParses() {  // M2.T20
        #expect(LaunchOptions.parse(["-OnboardingProbe", "/tmp/onb"]).onboardingProbe == "/tmp/onb")
    }

    @Test func fakeLAContextParses() {  // M2.T17
        #expect(LaunchOptions.parse(["-FakeLAContext", "succeed"]).fakeLAContext == true)
        #expect(LaunchOptions.parse(["-FakeLAContext", "fail"]).fakeLAContext == false)
        #expect(LaunchOptions.parse(["-FakeLAContext", "maybe"]).errors.count == 1)
    }

    @Test func fakeThermalAndPressureParse() {  // M2.T14
        let o = LaunchOptions.parse(["-FakeThermal", "Serious", "-FakePressure", "critical"])
        #expect(o.fakeThermal == "serious" && o.fakePressure == "critical" && o.errors.isEmpty)
        #expect(LaunchOptions.parse(["-FakeThermal", "hot", "-FakePressure", "high"]).errors.count == 2)
    }

    @Test func fakePowerAndDownloadHostParse() {  // M2.T09
        let o = LaunchOptions.parse(["-FakePower", "battery:7", "-DownloadHost", "http://127.0.0.1:8765"])
        #expect(o.fakePower == "battery:7" && o.downloadHost == "http://127.0.0.1:8765" && o.errors.isEmpty)
        #expect(LaunchOptions.parse(["-FakePower", "battery:300"]).errors.count == 1)
        #expect(LaunchOptions.parse(["-FakePower", "lowpower"]).fakePower == "lowpower")
    }

    @Test func fakeHardwareFixtureParses() {  // M2.T01
        let o = LaunchOptions.parse(["-FakeHardware", "t2-m4-24", "-FakeFreeDiskGB", "12", "-PrintHardwareProfile", "YES"])
        #expect(o.fakeHardware == .T2)
        #expect(o.fakeHardwareFixture == "t2-m4-24")
        #expect(o.fakeFreeDiskGB == 12)
        #expect(o.printHardwareProfile)
        let u = LaunchOptions.parse(["-FakeHardware", "unknown-m7-32"])
        #expect(u.fakeHardwareFixture == "unknown-m7-32" && u.fakeHardware == nil && u.errors.isEmpty)
    }

    @Test func networkOptionsParse() {  // M2.T03
        let o = LaunchOptions.parse(["-FakeNetwork", "none", "-TestProxy", "127.0.0.1:8899"])
        #expect(o.fakeNetwork == "none" && o.testProxyHost == "127.0.0.1" && o.testProxyPort == 8899)
        #expect(LaunchOptions.parse(["-FakeNetwork", "wifi", "-TestProxy", "nope"]).errors.count == 2)
    }

    @Test func catalogURLParses() {  // M2.T05
        #expect(LaunchOptions.parse(["-CatalogURL", "http://127.0.0.1:4321/catalog/v2/catalog.json"]).catalogURL
            == "http://127.0.0.1:4321/catalog/v2/catalog.json")
        #expect(LaunchOptions.parse(["-CatalogURL", "not a url"]).errors.count == 1)
    }

    @Test func menusProbeParses() {  // M1.T17
        #expect(LaunchOptions.parse(["app", "-MenusProbe", "/tmp/menus"]).menusProbe == "/tmp/menus")
    }

    @Test func macIntegrationOptionsParse() {  // M8.T12–T14
        let o = LaunchOptions.parse(["app", "-NotificationSpy", "/tmp/n.json", "-MacIntegrationProbe", "/tmp/mi",
                                     "-QuickPanelHotkeyHook", "YES"])
        #expect(o.notificationSpy == "/tmp/n.json")
        #expect(o.macIntegrationProbe == "/tmp/mi")
        #expect(o.quickPanelHotkeyHook)
        #expect(o.isAutomationRun)
        #expect(!LaunchOptions.parse(["app"]).quickPanelHotkeyHook)
    }

    @Test func helpSpyOptionsParse() {  // M10.T06/T07
        let o = LaunchOptions.parse(["app", "-OpenURLSpy", "/tmp/opened.txt", "-SimulateUpdatedFrom", "0.0.0"])
        #expect(o.openURLSpy == "/tmp/opened.txt")
        #expect(o.simulateUpdatedFrom == "0.0.0")
        #expect(LaunchOptions.parse(["app"]).openURLSpy == nil)
        #expect(LaunchOptions.parse(["app", "-OpenURLSpy", ""]).errors == ["-OpenURLSpy: empty path"])
    }

    @Test func finalAcceptanceProbeParses() {  // M10.T09
        let o = LaunchOptions.parse(["app", "-FinalAcceptanceProbe", "/tmp/fa"])
        #expect(o.finalAcceptanceProbe == "/tmp/fa")
        #expect(o.isAutomationRun)
        #expect(LaunchOptions.parse(["app"]).finalAcceptanceProbe == nil)
    }

    @Test func scriptedEngineNOMeansRealEngines() {
        #expect(LaunchOptions.parse(["-UseScriptedEngine", "NO"]).scriptedEngineScript == nil)
    }

    @Test func malformedValuesAreReportedAndIgnored() {
        let o = LaunchOptions.parse([
            "-FakeHardware", "T9", "-RendererCPUScale", "2", "-FakeContextWindow", "-5",
            "-OfflineOnly", "maybe", "-FixedClock", "yesterday", "-showContextUsage",
        ])
        #expect(o.fakeHardware == nil)
        #expect(o.rendererCPUScale == nil)
        #expect(o.fakeContextWindow == nil)
        #expect(o.offlineOnly == false)
        #expect(o.fixedClock == nil)
        #expect(o.showContextUsage == nil)
        #expect(o.errors.count == 6)
    }

    @Test func unknownArgumentsAreIgnored() {
        let o = LaunchOptions.parse(["-NSDocumentRevisionsDebugMode", "YES", "-SpikeUI", "YES"])
        #expect(o.isEmpty)
        #expect(o.errors.isEmpty)
    }
}
