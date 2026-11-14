// M3.T11 step 6 (S-16, IS-9): the VoiceOverlay above the composer in every state — connecting, listening, the user
// speaking (live caption), thinking, speaking (the spoken sentence), muted microphone, muted speaker, error
// (`voice.noDevice` + End) — light and dark, plus an Evil and an Incognito composer; the orb's Reduce Motion form (a
// static orb with opacity steps) is the snapshot default (`reduceMotionOverride`). Re-record after an intended visual
// change: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=VoiceOverlaySnapshotTests.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct VoiceOverlaySnapshotTests {
    func composer(_ phase: VoiceSessionController.Phase, caption: String = "", micMuted: Bool = false,
                  speakerMuted: Bool = false, mode: ComposerChatMode = .normal, incognito: Bool = false) -> some View {
        let model = ComposerModel()
        model.mode = mode
        model.isIncognito = incognito
        let v = VoiceSessionController(engine: NoVoiceEngine(), models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil)
        v.setPreviewState(phase, caption: caption, level: -28, micMuted: micMuted, speakerMuted: speakerMuted)
        model.voice = v
        return ComposerView(model: model)
    }

    func check(_ view: some View, name: String) {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(view, width: 680, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "voiceOverlay")
        }
    }

    @Test func connecting() { check(composer(.connecting), name: "connecting") }
    @Test func listening() { check(composer(.listening), name: "listening") }
    @Test func userSpeaking() { check(composer(.userSpeaking, caption: "what's a good name for a"), name: "userSpeaking") }
    @Test func thinking() { check(composer(.thinking), name: "thinking") }
    @Test func speaking() {
        check(composer(.speaking, caption: "How about Juniper, it is short and easy to call out."), name: "speaking")
    }
    @Test func mutedMic() { check(composer(.listening, micMuted: true), name: "mutedMic") }
    @Test func mutedSpeaker() { check(composer(.speaking, speakerMuted: true), name: "mutedSpeaker") }
    @Test func error() { check(composer(.error("voice.noDevice")), name: "error") }
    @Test func evil() { check(composer(.listening, mode: .evil), name: "evil") }
    @Test func incognito() { check(composer(.speaking, caption: "Sure.", incognito: true), name: "incognito") }

    @Test func idleHidesTheOverlay() {
        let model = ComposerModel()
        let v = VoiceSessionController(engine: NoVoiceEngine(), models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil)
        model.voice = v
        #expect(!model.isInVoiceSession)
        v.setPreviewState(.listening)
        #expect(model.isInVoiceSession)
        v.setPreviewState(.idle)
        #expect(!model.isInVoiceSession)
    }
}
}  // extension WindowSuites
