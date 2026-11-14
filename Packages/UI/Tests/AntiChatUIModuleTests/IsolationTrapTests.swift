// Isolation audit (docs/prd/reviews/isolation-audit.md): callbacks that frameworks call off the main thread must be
// nonisolated. A main-actor closure called there traps Swift 6's runtime isolation check (EXC_BREAKPOINT in
// `_dispatch_assert_queue_fail`) and would end this test process, so each test calls the handler from a background
// queue the way the framework does and expects the main-actor half to run on the main thread.
@preconcurrency import AVFAudio
import AppKit
@testable import AntiChatUI
import Testing

@Suite(.isolatedSettings) struct IsolationTrapTests {
    /// AppRelaunch (`openApplication`, private queue) and the uninstall `recycle` completion.
    @Test func workspaceCompletionCalledOffMainHopsToTheMainActor() async {
        let relaunch: (onMain: Bool, error: Bool) = await withCheckedContinuation { c in
            let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = WorkspaceCompletion.onMain { err in
                c.resume(returning: (Thread.isMainThread, err != nil))
            }
            DispatchQueue.global(qos: .userInitiated).async { done(nil, nil) }
        }
        #expect(relaunch.onMain && !relaunch.error)

        let recycle: (onMain: Bool, error: Bool) = await withCheckedContinuation { c in
            let done: @Sendable ([URL: URL], (any Error)?) -> Void = WorkspaceCompletion.onMain { err in
                c.resume(returning: (Thread.isMainThread, err != nil))
            }
            DispatchQueue(label: "test.recycle").async { done([:], CocoaError(.fileNoSuchFile)) }
        }
        #expect(recycle.onMain && recycle.error)
    }

    /// Settings › Voice level meter: the input tap runs on the audio render thread.
    @Test func levelTapCalledOffMainDeliversOnTheMainActor() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for i in 0 ..< 160 { buffer.floatChannelData![0][i] = 0.5 }
        let got: (onMain: Bool, level: Double) = await withCheckedContinuation { c in
            nonisolated(unsafe) let tap = InputLevelMeter.tapBlock { v in c.resume(returning: (Thread.isMainThread, v)) }
            nonisolated(unsafe) let b = buffer
            DispatchQueue.global(qos: .userInteractive).async { tap(b, AVAudioTime(hostTime: 0)) }
        }
        #expect(got.onMain)
        #expect(got.level > 0.5)  // 0.5 full scale ≈ −6 dBFS → 0.9
    }
}
