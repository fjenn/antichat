// M5.T12 (R-045 AC1; AT-045 AC1 in-process leg while XCUITest cannot run, Q-015): the inline player's defaults — loop
// on for clips ≤ 10 s and off above, muted when the clip has no sound track and unmuted when it has one — on real MP4s
// (AVPlayerLooper attached while looping), the toggles, the duration label, and the result card's done state (poster
// first + ⋯ with Export MP4) light/dark.
// Re-record: SNAPSHOT_TESTING_RECORD=all swift test --filter InlineVideoPlayerTests.
import AVFoundation
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

enum TestClips {
    /// A 32×32 H.264 clip of `seconds` (one frame per second, ≥ 2 frames) with an AAC track when `sound`.
    static func make(seconds: Int, sound: Bool, in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("clip-\(seconds)-\(sound).mp4")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32,
                                                                       AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32,
            kCVPixelBufferHeightKey as String: 32,
        ])
        writer.add(v)
        var a: AVAssetWriterInput?
        if sound {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            writer.add(i)
            a = i
        }
        guard writer.startWriting() else { throw CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        if let a {
            let n = 48_000 * seconds
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let p = buf.floatChannelData![0]
            for i in 0..<n { p[i] = sinf(Float(i) * 0.05) * 0.1 }
            var desc: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: fmt.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sb: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                 formatDescription: desc!, sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
            CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                                                           bufferList: buf.audioBufferList)
            while !a.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            _ = a.append(sb!)
            a.markAsFinished()
        }
        for i in 0...max(1, seconds) {
            while !v.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(40 + i * 10), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            _ = adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 1))
        }
        v.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct InlineVideoPlayerTests {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ivp-tests")

    @Test func defaultsRule() {
        #expect(VideoPlaybackDefaults.defaults(duration: 3.4, hasSound: false) == .init(loops: true, muted: true))
        #expect(VideoPlaybackDefaults.defaults(duration: 10, hasSound: true) == .init(loops: true, muted: false))
        #expect(VideoPlaybackDefaults.defaults(duration: 10.5, hasSound: true) == .init(loops: false, muted: false))
        #expect(VideoPlaybackDefaults.defaults(duration: 0, hasSound: false).loops == false, "unknown length: no loop")
        #expect(InlineVideoPlayerModel.durationLabel(3.4) == "0:03" && InlineVideoPlayerModel.durationLabel(65) == "1:05")
    }

    @Test func shortSilentClipLoopsMuted() async throws {
        let m = InlineVideoPlayerModel(url: try await TestClips.make(seconds: 3, sound: false, in: Self.dir))
        await m.load()
        #expect(m.phase == .ready && abs(m.duration - 3) < 0.1 && !m.hasSound)
        #expect(m.loops, "loop on by default for ≤ 10 s")
        #expect(m.isMuted && m.player.isMuted, "muted: the clip has no sound")
        // AVPlayerLooper fills the queue with copies of the item.
        #expect(m.player.items().count >= 1)
        m.setLoops(false)
        #expect(!m.loops && m.player.items().count == 1)
        m.setMuted(false)
        #expect(!m.player.isMuted)
    }

    @Test func longClipWithSoundDoesNotLoopAndPlaysAloud() async throws {
        let m = InlineVideoPlayerModel(url: try await TestClips.make(seconds: 12, sound: true, in: Self.dir))
        await m.load()
        #expect(m.hasSound && abs(m.duration - 12) < 0.1)
        #expect(!m.loops, "loop off above 10 s")
        #expect(!m.isMuted && !m.player.isMuted, "unmuted: the clip has sound")
        #expect(m.player.items().count == 1)
        m.setLoops(true)
        #expect(m.loops)
        m.play()
        #expect(m.started && m.phase == .playing)
        m.seek(fraction: 0.5)
        m.pause()
        #expect(m.phase == .ready)
    }

    @Test func unreadableFileIsAnError() async {
        let bad = Self.dir.appendingPathComponent("broken.mp4")
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? Data("not a movie".utf8).write(to: bad)
        let m = InlineVideoPlayerModel(url: bad)
        await m.load()
        #expect(m.phase == .error)
    }

    @Test func suggestedExportName() {
        #expect(VideoSavePanel.suggestedName("video.mp4") == "video.mp4")
        #expect(VideoSavePanel.suggestedName(nil) == "Video.mp4")
        #expect(VideoSavePanel.suggestedName("waves.mov") == "waves.mp4")
    }

    @Test func doneCardSnapshots() async throws {
        let clip = try await TestClips.make(seconds: 3, sound: false, in: Self.dir)
        let poster = Self.dir.appendingPathComponent("poster.png")
        let img = NSImage(size: NSSize(width: 160, height: 90), flipped: false) { r in
            NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.7, alpha: 1).setFill()
            r.fill()
            return true
        }
        try NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: poster)
        var s = VideoJobCardState(job: "v1", aspect: 16.0 / 9, startedAt: .distantFuture)
        s.width = 1280; s.height = 704; s.frames = 81; s.fps = 24
        s.progress.finished()
        s.phase = .done(resultPath: clip.path)
        for look in ResponseActionsSnapshotTests.Look.allCases {
            let v = VideoJobCard(state: s, poster: poster.path).environment(\.reduceMotionOverride, true)
            assertSnapshot(of: ResponseActionsSnapshotTests.render(v, width: 420, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98), named: "done-\(look.rawValue)",
                           testName: "inlineVideoPlayer")
        }
    }
}
}  // extension WindowSuites
