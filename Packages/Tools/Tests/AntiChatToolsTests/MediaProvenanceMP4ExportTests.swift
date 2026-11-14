// M5.T12 (R-045 AC2, R-287 AC2; AT-045 export part, in-process leg while XCUITest cannot run, Q-015): Export MP4 of a
// stored clip. The source is shaped like MP4Encoder's output (M5.T05: H.264, `dscp` "<prompt> — model … · seed … ·
// steps …", `swre` AntiChat, XMP uuid box with the AI mark); a plain export is byte-identical, a stripped one plays,
// keeps DigitalSourceType + model/seed/steps/operation and has the prompt nowhere in the file.
//   swift test --filter MediaProvenanceMP4ExportTests
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AntiChatTools

@Suite struct MediaProvenanceMP4ExportTests {
    static let prompt = "a red kite over misty hills"

    static func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mp4export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A 0.5 s 64×64 H.264 clip with MP4Encoder's metadata (+ AAC audio when `audio`).
    static func clip(at url: URL, audio: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.metadata = MediaProvenanceWriter.mp4UserData(summary: "\(prompt) — model vid-5b · seed 7 · steps 3")
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64,
                                                                       AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(v)
        var a: AVAssetWriterInput?
        if audio {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            writer.add(i)
            a = i
        }
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        if let a {
            let n = 24_000
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let p = buf.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<(n * 2) { p[i] = sinf(Float(i / 2) * 0.05) * 0.2 }
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
            #expect(a.append(sb!))
            a.markAsFinished()
        }
        for i in 0..<12 {
            while !v.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(i * 20), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            #expect(adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24)))
        }
        v.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        // The XMP packet MP4Encoder.xmp(_:) writes.
        let m = CGImageMetadataCreateMutable()
        var err: Unmanaged<CFError>?
        _ = CGImageMetadataRegisterNamespaceForPrefix(m, MediaProvenanceWriter.namespace as CFString, "antichat" as CFString, &err)
        for (path, value) in [("Iptc4xmpExt:DigitalSourceType", MediaProvenanceWriter.digitalSourceType), ("xmp:CreatorTool", "AntiChat"),
                              ("dc:description", "\(prompt) — model vid-5b · seed 7 · steps 3"), ("antichat:model", "vid-5b"),
                              ("antichat:seed", "7"), ("antichat:steps", "3"), ("antichat:operation", "generate")] {
            #expect(CGImageMetadataSetValueWithPath(m, nil, path as CFString, value as CFString))
        }
        try MediaProvenanceWriter.appendXMPBox(CGImageMetadataCreateXMPData(m, nil)! as Data, to: url)
    }

    static func userData(_ url: URL) async throws -> [String] {
        var out: [String] = []
        for item in try await AVURLAsset(url: url).load(.metadata) {
            if let s = try await item.load(.stringValue) { out.append(s) }
        }
        return out
    }

    @Test func plainExportIsTheStoredFile() async throws {
        let d = try Self.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("clip.mp4"), out = d.appendingPathComponent("Exported.mp4")
        try await Self.clip(at: src)
        try Data("old".utf8).write(to: out)  // replaced
        try await MediaProvenanceWriter.exportMP4(src, to: out, stripPrompt: false)
        #expect(try Data(contentsOf: out) == Data(contentsOf: src))
        #expect(try await AVURLAsset(url: out).load(.isPlayable))
        let x = try #require(try MediaProvenanceWriter.xmpData(ofMP4: out)).map(MediaProvenanceWriter.fields) ?? [:]
        #expect(x["Iptc4xmpExt:DigitalSourceType"] == MediaProvenanceWriter.digitalSourceType)
        #expect(x["dc:description"]?.contains(Self.prompt) == true, "metadata preserved")
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).sorted() == ["Exported.mp4", "clip.mp4"], "no staging left")
    }

    @Test(arguments: [false, true]) func strippedExportPlaysKeepsTheMarkAndDropsThePrompt(audio: Bool) async throws {
        let d = try Self.dir()
        defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("clip.mp4"), out = d.appendingPathComponent("Exported.mp4")
        try await Self.clip(at: src, audio: audio)
        try await MediaProvenanceWriter.exportMP4(src, to: out, stripPrompt: true)
        let asset = AVURLAsset(url: out)
        #expect(try await asset.load(.isPlayable), "the exported file plays")
        #expect(try await asset.loadTracks(withMediaType: .audio).count == (audio ? 1 : 0), "the sound track is kept")
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.05)
        let x = try #require(try MediaProvenanceWriter.xmpData(ofMP4: out)).map(MediaProvenanceWriter.fields) ?? [:]
        #expect(x["Iptc4xmpExt:DigitalSourceType"] == MediaProvenanceWriter.digitalSourceType, "AI mark kept")
        #expect(x["xmp:CreatorTool"] == "AntiChat")
        #expect(x["antichat:model"] == "vid-5b" && x["antichat:seed"] == "7" && x["antichat:steps"] == "3"
                && x["antichat:operation"] == "generate")
        #expect(x["dc:description"] == "model vid-5b · seed 7 · steps 3")
        let ud = try await Self.userData(out)
        #expect(ud.contains("model vid-5b · seed 7 · steps 3") && ud.contains("AntiChat"))
        let bytes = try Data(contentsOf: out)
        #expect(bytes.range(of: Data(Self.prompt.utf8)) == nil, "the prompt is nowhere in the file")
        #expect(try Data(contentsOf: src).range(of: Data(Self.prompt.utf8)) != nil, "the stored clip keeps it")
    }

    @Test func strippingAPacketWithoutGenerationFieldsKeepsOnlyTheMark() throws {
        let m = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(m, nil, "dc:description" as CFString, "secret" as CFString))
        let clean = try #require(MediaProvenanceWriter.strippingPrompt(xmp: CGImageMetadataCreateXMPData(m, nil)! as Data))
        let f = MediaProvenanceWriter.fields(clean)
        #expect(f["dc:description"] == nil && f["Iptc4xmpExt:DigitalSourceType"] == MediaProvenanceWriter.digitalSourceType)
        #expect(clean.range(of: Data("secret".utf8)) == nil)
    }
}
