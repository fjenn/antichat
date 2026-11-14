// M5.T05 task checks (R-040 result, R-287 AC3, R-292): MP4Encoder on ScriptedVideoEngine frames (content-free
// gradients) → a playable MP4 whose duration is frames / fps ± 1 frame and whose R-287 metadata reads back; the
// poster frame is a JPEG of the first frame; AVSyncTests: a white flash and a click at the same instant stay within
// 40 ms of each other after the mux.
import AntiChatEngineProtocol
import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import AntiChatEngines

@Suite struct MP4EncoderTests {
    static func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mp4enc-\(UUID().uuidString)/\(name)")
    }

    static func frames(_ n: Int, _ w: Int, _ h: Int) -> [Data] {
        (0..<n).map { ScriptedVideoEngine.gradientRGBA(width: w, height: h, phase: $0) }
    }

    /// XMP fields of the MP4's `uuid` box, by `prefix:name`.
    static func xmp(_ url: URL) throws -> [String: String] {
        let data = try #require(try MP4Encoder.readXMP(url))
        let m = try #require(CGImageMetadataCreateFromXMPData(data as CFData))
        var out: [String: String] = [:]
        for tag in (CGImageMetadataCopyTags(m) as? [CGImageMetadataTag]) ?? [] {
            let key = "\(CGImageMetadataTagCopyPrefix(tag) ?? "" as CFString):\(CGImageMetadataTagCopyName(tag) ?? "" as CFString)"
            if let v = CGImageMetadataTagCopyValue(tag) as? String { out[key] = v }
            else if let a = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag], let f = a.first,
                    let v = CGImageMetadataTagCopyValue(f) as? String { out[key] = v }
        }
        return out
    }

    static func metadata(_ url: URL) async throws -> [String: String] {
        let asset = AVURLAsset(url: url)
        var out: [String: String] = [:]
        for item in try await asset.load(.metadata) {
            let key = item.identifier?.rawValue ?? "?"
            out[key] = try await item.load(.stringValue)
        }
        return out
    }

    @Test func playableWithDurationAndMetadata() async throws {
        let url = Self.tmp("video.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let info = MP4Encoder.Info(prompt: "waves on a beach", model: "vid-5b", seed: 7, steps: 3)
        let codec = try await MP4Encoder.encode(frames: Self.frames(25, 320, 192), width: 320, height: 192, fps: 16, info: info, to: url)
        #expect(codec == .h264)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        let d = try await asset.load(.duration).seconds
        #expect(abs(d - 25.0 / 16.0) <= 1.0 / 16.0 + 1e-6, "duration \(d)")
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 192))
        let m = try await Self.metadata(url)
        #expect(m.values.contains("AntiChat"))
        #expect(m.values.contains("waves on a beach — model vid-5b · seed 7 · steps 3"))
        let x = try Self.xmp(url)
        #expect(x["Iptc4xmpExt:DigitalSourceType"] == MP4Encoder.digitalSourceType)
        #expect(x["xmp:CreatorTool"] == "AntiChat")
        #expect(x["dc:description"] == "waves on a beach — model vid-5b · seed 7 · steps 3")
        #expect(x["antichat:model"] == "vid-5b")
        #expect(x["antichat:seed"] == "7")
        #expect(x["antichat:steps"] == "3")
        #expect(x["antichat:operation"] == "generate")
    }

    @Test func stripPromptKeepsTheMark() async throws {
        let url = Self.tmp("video.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let info = MP4Encoder.Info(prompt: "secret prompt", model: "vid-i2v", seed: 1, steps: 20, operation: "animate", stripPrompt: true)
        try await MP4Encoder.encode(frames: Self.frames(5, 64, 64), width: 64, height: 64, fps: 24, info: info, to: url)
        let m = try await Self.metadata(url)
        let x = try Self.xmp(url)
        #expect(!m.values.contains { $0.contains("secret prompt") })
        #expect(!x.values.contains { $0.contains("secret prompt") })
        #expect(x["Iptc4xmpExt:DigitalSourceType"] == MP4Encoder.digitalSourceType)
        #expect(x["antichat:model"] == "vid-i2v")
        #expect(x["antichat:operation"] == "animate")
        #expect(m.values.contains("model vid-i2v · seed 1 · steps 20"))
    }

    @Test func hevcAtWideFrames() async throws {
        let url = Self.tmp("video.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let codec = try await MP4Encoder.encode(frames: Self.frames(3, 1280, 720), width: 1280, height: 720, fps: 24,
                                                info: .init(prompt: "p", model: "m", seed: 1, steps: 1), to: url)
        // Apple silicon encodes HEVC in hardware; H.264 is the documented fallback (M5.T05 failure mode).
        #expect(codec == .hevc || codec == .h264)
        #expect(try await AVURLAsset(url: url).load(.isPlayable))
    }

    @Test func rejectsBadInput() async {
        let url = Self.tmp("video.mp4")
        await #expect(throws: (any Error).self) {
            try await MP4Encoder.encode(frames: [Data(count: 10)], width: 64, height: 64, fps: 24,
                                        info: .init(prompt: "p", model: "m", seed: 1, steps: 1), to: url)
        }
        await #expect(throws: (any Error).self) {
            try await MP4Encoder.encode(frames: [], width: 64, height: 64, fps: 24, info: .init(prompt: "p", model: "m", seed: 1, steps: 1), to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func posterFrameIsAJPEGOfTheFirstFrame() throws {
        let f = ScriptedVideoEngine.gradientRGBA(width: 64, height: 48, phase: 0)
        let jpeg = try #require(PosterFrame.jpeg(rgba: f, width: 64, height: 48))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(PosterFrame.jpeg(rgba: Data(count: 3), width: 64, height: 48) == nil)
    }
}

@Suite struct AVSyncTests {
    /// Clap-and-flash: black frames with one white frame at `flash`; a 48 kHz stereo track, silent but for a click at
    /// the same instant. After the mux, the first bright frame's PTS and the first loud audio sample's time differ by
    /// ≤ 40 ms.
    @Test func flashAndClickStayInSync() async throws {
        let (w, h, fps, n, flash) = (64, 64, 24.0, 48, 30)
        let black = Data(repeating: 0, count: w * h * 4)
        let white = Data(repeating: 255, count: w * h * 4)
        let frames = (0..<n).map { $0 == flash ? white : black }
        let rate = MP4Encoder.audioSampleRate
        let total = Int(Double(n) / fps * rate)
        let clickAt = Int(Double(flash) / fps * rate)
        var pcm = [Float](repeating: 0, count: total * 2)
        for i in clickAt..<min(total, clickAt + 480) { pcm[2 * i] = 0.9; pcm[2 * i + 1] = 0.9 }
        let audio = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        let url = MP4EncoderTests.tmp("sync.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await MP4Encoder.encode(frames: frames, width: w, height: h, fps: fps, audio: audio,
                                    info: .init(prompt: "sync", model: "m", seed: 1, steps: 1), to: url)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        let vt = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let at = try #require(try await asset.loadTracks(withMediaType: .audio).first)

        // Video: first frame whose centre pixel is bright.
        let vr = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vr.add(vo)
        vr.startReading()
        var flashT: Double?
        while let sb = vo.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let v = p[(h / 2) * CVPixelBufferGetBytesPerRow(pb) + (w / 2) * 4 + 1]
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            if v > 128 { flashT = CMSampleBufferGetPresentationTimeStamp(sb).seconds; break }
        }
        vr.cancelReading()

        // Audio: first decoded sample above 0.3.
        let ar = try AVAssetReader(asset: asset)
        let ao = AVAssetReaderTrackOutput(track: at, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        ])
        ar.add(ao)
        ar.startReading()
        var clickT: Double?
        while clickT == nil, let sb = ao.copyNextSampleBuffer() {
            let t0 = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            let samples = UnsafeRawPointer(ptr!).assumingMemoryBound(to: Float.self)
            for i in 0..<(len / 4) where abs(samples[i]) > 0.3 {
                clickT = t0 + Double(i / 2) / rate
                break
            }
        }
        ar.cancelReading()
        let f = try #require(flashT), c = try #require(clickT)
        #expect(abs(f - c) <= 0.040, "flash \(f) s, click \(c) s")
    }
}
