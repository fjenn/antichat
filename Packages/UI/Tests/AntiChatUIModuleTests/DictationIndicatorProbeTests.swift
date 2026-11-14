// M3.T03 AT-NFR-V5 probe (S-17): mic click → recording indicator, in-process. The composer is hosted in a window; a
// run = `startDictation()` (what MicButton calls once the permission is granted, signpost `dictation.click`) → the
// next layout + display pass that draws the DictationBar (`dictation.indicator`). The helper is a stand-in that never
// answers: the bar must not wait for it. Runs only as the perf probe (`make perf METRIC=V5`, which sets
// ANTICHAT_V5_OUT=<json>); a timing assertion in the unit run would be load-dependent.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AppKit
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

final class SilentVoiceEngine: EngineService, @unchecked Sendable {
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch> { AsyncStream { _ in } }  // never answers
    func voiceSend(_ message: VoiceMessage) -> Bool { true }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_V5_OUT"] != nil), .isolatedSettings)
struct DictationIndicatorProbeTests {
    @Test func clickToIndicator() throws {
        let runs = Int(ProcessInfo.processInfo.environment["ANTICHAT_V5_RUNS"] ?? "") ?? 20
        let model = ComposerModel()
        let d = DictationController(engine: SilentVoiceEngine(), models: { VoiceModelSet(slots: [:]) }, scriptedInput: nil)
        model.dictation = d
        let host = NSHostingView(rootView: ComposerView(model: model).frame(width: 680).padding(24).background(Color.surfaceCanvas))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        _ = NSApplication.shared
        BackgroundRun.present(window)  // concealed, never activates (audit no-focus-steal)
        defer { window.orderOut(nil) }
        var ms: [Double] = []
        for i in 0...runs {
            host.layoutSubtreeIfNeeded(); host.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let t0 = DispatchTime.now().uptimeNanoseconds
            model.startDictation()
            host.layoutSubtreeIfNeeded()
            host.display()
            let t1 = DispatchTime.now().uptimeNanoseconds
            #expect(model.isDictating)
            if i > 0 { ms.append(Double(t1 - t0) / 1e6) }  // run 0 = first-use warm-up (fonts, view graph)
            d.stop(.cancel)
            d.reset()
            host.layoutSubtreeIfNeeded(); host.display()
        }
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANTICHAT_V5_OUT"]!)
        try JSONSerialization.data(withJSONObject: ["v5_ms": ms, "load": ProcessInfo.processInfo.systemUptime]).write(to: out)
        print("V5 click → indicator ms: \(ms.map { String(format: "%.1f", $0) }.joined(separator: " "))")
    }
}
}  // extension WindowSuites
