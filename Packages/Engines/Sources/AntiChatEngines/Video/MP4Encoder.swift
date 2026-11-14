// M5.T05 (R-040 result, R-287 AC3, R-292; P-media-11 source 4, P-media-09): MP4 encode/mux of a video job's frames
// with AVAssetWriter. Called ONLY by `MediaJobRunner.emitVideoResult` after `MediaOutputGate.checkVideo` returned
// `allow` (M5.T06); nothing else in the tree encodes generated frames.
//   - video: H.264 High (HEVC when the width is ≥ 1280 and the writer accepts it), 4 Mb/s at ≤ 480p, 8 Mb/s above;
//     RGBA8 frames → BGRA pixel buffers (vImage), PTS = frame / fps;
//   - audio (optional, T3+ sound track, M5.T07): 48 kHz stereo interleaved Float32 PCM in (`audioSampleRate`), AAC
//     48 kHz stereo 160 kb/s out, PTS from the sample count, so the A/V
//     offset is the rounding of one frame time at most (≤ 40 ms, AVSyncTests);
//   - metadata (R-287 AC3, the M4.T09 step 3 contract, adapted to MP4): an `.mp4` AVAssetWriter keeps only the
//     ISO user-data keys it knows (QuickTime `mdta` and iTunes items are dropped; probed), so the MP4 carries
//     `uiso/dscp` (the Get-Info line: prompt — model · seed · steps; the prompt omitted when stripped) and `uiso/swre`
//     "AntiChat", and the AI mark plus generation info go into a standard XMP `uuid` box (Adobe XMP spec part 3,
//     BE7ACFCB-97A9-42E8-9C71-999491E3AFAC) appended at the top level: `Iptc4xmpExt:DigitalSourceType` =
//     trainedAlgorithmicMedia, `xmp:CreatorTool`, `dc:description`, `antichat:{model,seed,steps,operation,parent}`.
//     M4.T09 (not built yet) owns the image half and can reuse `xmp(_:)` (A-M5-08).
import Accelerate
import AntiChatFoundation
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

public enum MP4Encoder {
    /// Generation details written into the MP4 (R-287).
    public struct Info: Sendable, Equatable {
        public var prompt: String
        public var model: String
        public var seed: Int64
        public var steps: Int
        /// `generate` or `animate` (R-287 AC4 lineage operation).
        public var operation: String
        public var parent: String?
        /// "Save without prompt details": the prompt goes, the AI mark and the model id stay (R-287 AC2).
        public var stripPrompt: Bool

        public init(prompt: String, model: String, seed: Int64, steps: Int, operation: String = "generate", parent: String? = nil,
                    stripPrompt: Bool = false) {
            self.prompt = prompt
            self.model = model
            self.seed = seed
            self.steps = steps
            self.operation = operation
            self.parent = parent
            self.stripPrompt = stripPrompt
        }
    }

    public static let digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
    public static let antichatNS = "http://antichat.app/ns/1.0/"
    /// The XMP `uuid` box type of ISO BMFF files (Adobe XMP specification part 3).
    public static let xmpUUID: [UInt8] = [0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC]

    /// Encodes `frames` (RGBA8, `width × height × 4` each) at `fps` (+ optional audio) to `url` (replaced if present).
    /// Returns the codec used.
    public static let audioSampleRate = 48_000.0

    @discardableResult
    public static func encode(frames: [Data], width: Int, height: Int, fps: Double, audio: Data? = nil, info: Info,
                              to url: URL) async throws -> AVVideoCodecType {
        guard (2...16_384).contains(width), (2...16_384).contains(height), !frames.isEmpty, fps.isFinite, fps > 0 else {
            throw mediaError("videoBadGeometry", "\(width)x\(height) n=\(frames.count) fps=\(fps)")
        }
        let frameBytes = width * height * 4
        guard frames.allSatisfy({ $0.count == frameBytes }) else { throw mediaError("videoBadFrame", "size") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.metadata = metadata(info)

        let bitrate = min(width, height) <= 480 ? 4_000_000 : 8_000_000
        func settings(_ codec: AVVideoCodecType) -> [String: Any] {
            var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            return [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: compression]
        }
        let codec: AVVideoCodecType = width >= 1280 && writer.canApply(outputSettings: settings(.hevc), forMediaType: .video) ? .hevc : .h264
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings(codec))
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(vIn) else { throw mediaError("videoWriter", "cannot add video input") }
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if audio != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
            ])
            a.expectsMediaDataInRealTime = false
            guard writer.canAdd(a) else { throw mediaError("videoWriter", "cannot add audio input") }
            writer.add(a)
            aIn = a
        }
        guard writer.startWriting() else { throw mediaError("videoWriter", writer.error.map { "\($0)" }) }
        writer.startSession(atSourceTime: .zero)

        // Audio first in one go (a short clip's PCM is small); the writer interleaves.
        if let audio, let aIn {
            let sb = try sampleBuffer(try pcmBuffer(audio))
            while !aIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard aIn.append(sb) else { throw mediaError("videoWriter", writer.error.map { "\($0)" } ?? "audio append failed") }
            aIn.markAsFinished()
        }
        for (i, frame) in frames.enumerated() {
            while !vIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw mediaError("videoWriter", "no pixel buffer pool") }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let pb = out else { throw mediaError("videoWriter", "pixel buffer") }
            try rgbaToBGRA(frame, width: width, height: height, into: pb)
            guard adaptor.append(pb, withPresentationTime: pts(frame: i, fps: fps)) else {
                throw mediaError("videoWriter", writer.error.map { "\($0)" } ?? "append failed")
            }
        }
        vIn.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw mediaError("videoWriter", writer.error.map { "\($0)" }) }
        try appendXMP(xmp(info), to: url)
        return codec
    }

    /// Frame `i`'s presentation time (`i / fps`, 90 kHz timescale so 24/25/30/16 fps are exact or within 11 µs).
    public static func pts(frame i: Int, fps: Double) -> CMTime {
        CMTime(value: CMTimeValue((Double(i) * 90_000 / fps).rounded()), timescale: 90_000)
    }

    /// The Get-Info line (M4.T09 step 2 format): "<prompt> — model <id> · seed <n> · steps <s>", without the prompt
    /// when stripped.
    public static func summary(_ info: Info) -> String {
        let s = "model \(info.model) · seed \(info.seed) · steps \(info.steps)"
        return info.stripPrompt ? s : "\(info.prompt) — \(s)"
    }

    /// The ISO user-data items an `.mp4` writer keeps: description and software.
    public static func metadata(_ info: Info) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            return m
        }
        return [item(.commonIdentifierSoftware, "AntiChat"), item(.commonIdentifierDescription, summary(info))]
    }

    /// The XMP packet: the AI mark (always), creator tool, description and the generation fields.
    public static func xmp(_ info: Info) throws -> Data {
        let m = CGImageMetadataCreateMutable()
        var err: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(m, antichatNS as CFString, "antichat" as CFString, &err) else {
            throw mediaError("videoMetadata", "namespace")
        }
        var fields: [(String, String)] = [
            ("Iptc4xmpExt:DigitalSourceType", digitalSourceType), ("xmp:CreatorTool", "AntiChat"), ("dc:description", summary(info)),
            ("antichat:model", info.model), ("antichat:seed", "\(info.seed)"), ("antichat:steps", "\(info.steps)"),
            ("antichat:operation", info.operation),
        ]
        if let p = info.parent { fields.append(("antichat:parent", p)) }
        for (path, value) in fields where !CGImageMetadataSetValueWithPath(m, nil, path as CFString, value as CFString) {
            throw mediaError("videoMetadata", path)
        }
        guard let data = CGImageMetadataCreateXMPData(m, nil) else { throw mediaError("videoMetadata", "xmp") }
        return data as Data
    }

    /// Appends a top-level `uuid` XMP box (valid anywhere at the top level of an ISO BMFF file).
    static func appendXMP(_ xmp: Data, to url: URL) throws {
        var box = Data()
        withUnsafeBytes(of: UInt32(8 + 16 + xmp.count).bigEndian) { box.append(contentsOf: $0) }
        box.append(contentsOf: Array("uuid".utf8))
        box.append(contentsOf: xmpUUID)
        box.append(xmp)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: box)
    }

    /// The XMP packet of an MP4 written here (top-level `uuid` box), or nil.
    public static func readXMP(_ url: URL) throws -> Data? {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        var o = 0
        while o + 8 <= d.count {
            var raw = d[o..<o + 4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: d[o + 4..<o + 8], as: UTF8.self)
            if raw == 1, o + 16 <= d.count { raw = d[o + 8..<o + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }  // 64-bit size
            if raw == 0 { raw = UInt64(d.count - o) }  // to the end of the file
            // M5.T14 review P2: checked against the bytes left (a 64-bit size can never overflow `o + size`).
            guard raw <= UInt64(d.count - o) else { return nil }
            let size = Int(raw)
            guard size >= 8 else { return nil }
            if type == "uuid", size >= 24, Array(d[o + 8..<o + 24]) == xmpUUID { return d.subdata(in: o + 24..<o + size) }
            o += size
        }
        return nil
    }

    static func rgbaToBGRA(_ frame: Data, width: Int, height: Int, into pb: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw mediaError("videoWriter", "pixel buffer base") }
        var dst = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: CVPixelBufferGetBytesPerRow(pb))
        let err: vImage_Error = frame.withUnsafeBytes { raw in
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: width * 4)
            let map: [UInt8] = [2, 1, 0, 3]  // RGBA → BGRA
            return vImagePermuteChannels_ARGB8888(&src, &dst, map, vImage_Flags(kvImageNoFlags))
        }
        guard err == kvImageNoError else { throw mediaError("videoWriter", "vImage \(err)") }
    }

    /// Interleaved stereo Float32 at 48 kHz → a PCM buffer.
    static func pcmBuffer(_ d: Data) throws -> AVAudioPCMBuffer {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audioSampleRate, channels: 2, interleaved: true),
              d.count % 8 == 0, d.count > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(d.count / 8)) else {
            throw mediaError("videoBadAudio", "\(d.count) bytes")
        }
        buf.frameLength = AVAudioFrameCount(d.count / 8)
        d.withUnsafeBytes { src in
            let dst = buf.audioBufferList.pointee.mBuffers.mData!
            dst.copyMemory(from: src.baseAddress!, byteCount: d.count)
        }
        return buf
    }

    /// PCM buffer → one CMSampleBuffer at PTS 0 (timing from the sample count).
    static func sampleBuffer(_ buf: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var desc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: buf.format.streamDescription, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc) == noErr,
              let desc else { throw mediaError("videoWriter", "audio format") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buf.format.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: desc, sampleCount: CMItemCount(buf.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr,
              let sb,
              CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                                                             bufferList: buf.audioBufferList) == noErr
        else { throw mediaError("videoWriter", "audio sample buffer") }
        return sb
    }
}
