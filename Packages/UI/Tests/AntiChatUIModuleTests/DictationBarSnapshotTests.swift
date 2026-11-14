// M3.T03 step 5 (S-17, IS-9): the DictationBar in the composer — recording (level dots), partial text streaming
// (grey), finalizing (■ / ↑ dimmed), light and dark; the dots' Reduce Motion form is the snapshot default
// (`reduceMotionOverride`). Re-record after an intended visual change:
// SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=DictationBarSnapshotTests.
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
@Suite(.serialized, .isolatedSettings) struct DictationBarSnapshotTests {
    static let levels: [Float] = (0..<48).map { i in -55 + 35 * Float(abs(sin(Double(i) / 3.0))) }

    func composer(_ phase: DictationController.Phase, partial: String = "", basic: Bool = false) -> some View {
        let model = ComposerModel()
        let d = DictationController(engine: NoVoiceEngine(), models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil)
        d.setPreviewState(phase, partial: partial, levels: Self.levels, startedAt: nil, isBasic: basic)  // 0:00, deterministic
        model.dictation = d
        return ComposerView(model: model)
    }

    func check(_ view: some View, name: String) {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(view, width: 680, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "dictation")
        }
    }

    @Test func recording() { check(composer(.recording), name: "recording") }

    @Test func partialStreaming() {
        check(composer(.recording, partial: "Yea, his honourable worship is within, but he hath a godly minister"), name: "partial")
    }

    @Test func finalizing() {
        check(composer(.finalizing, partial: "Yea, his honourable worship is within"), name: "finalizing")
    }

    /// M3.T04 (R-281 AC1): "Basic voice" while the session runs on the system recogniser.
    @Test func basicVoice() { check(composer(.recording, partial: "Ye may not see his worship now", basic: true), name: "basic") }

    @Test func idleShowsTheField() {
        let model = ComposerModel()
        let d = DictationController(engine: NoVoiceEngine(), models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil)
        model.dictation = d
        #expect(!model.isDictating)
        d.setPreviewState(.empty)
        #expect(!model.isDictating, "silence-only: the bar goes, the field is back (R-050 AC3)")
        d.setPreviewState(.recording)
        #expect(model.isDictating)
    }

    @Test func elapsedFormat() {
        #expect(Elapsed.format(0) == "0:00" && Elapsed.format(7.9) == "0:07" && Elapsed.format(65) == "1:05")
    }
}
}  // extension WindowSuites

final class NoVoiceEngine: EngineService, @unchecked Sendable {
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
