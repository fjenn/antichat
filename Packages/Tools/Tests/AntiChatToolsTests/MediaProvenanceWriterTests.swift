// AT-287 (R-287) unit legs: the AI mark and the generation details in saved PNGs (AC1, AC2) and MP4s (AC3).
// `testPNGFields`, `testStripKeepsMark`, `testMP4MarkAndPlayable` are the AT-287 filter names.
import AVFoundation
import AntiChatStorage
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AntiChatTools

@Suite("MediaProvenanceWriterTests") struct MediaProvenanceWriterTests {
    static let info = GenerationInfo(prompt: "a lighthouse at dusk, café-style poster 🌅", model: "img-klein-q4", seed: 42,
                                     steps: 4, parent: "ver-1", operation: .edit, width: 64, height: 48)

    /// A plain 64×48 PNG with a sd.cpp-style `parameters` text chunk carrying a prompt.
    static func plainPNG() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        var chunks = try #require(PNGChunks(out as Data))
        chunks.insertAfterHeader([PNGChunks.text("parameters", "secret sd prompt, Steps: 4")])
        return chunks.data
    }

    static func pixels(_ png: Data) throws -> Data {
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        return try #require(img.dataProvider?.data) as Data
    }

    @Test func testPNGFields() throws {
        let plain = try Self.plainPNG()
        let png = try MediaProvenanceWriter.writePNG(plain, info: Self.info, stripPrompt: false)
        let m = try #require(MediaProvenanceWriter.metadata(png))
        #expect(MediaProvenanceWriter.string(m, "Iptc4xmpExt:DigitalSourceType") == MediaProvenanceWriter.digitalSourceType)
        let description = try #require(MediaProvenanceWriter.string(m, "dc:description"))
        #expect(description == "a lighthouse at dusk, café-style poster 🌅 — model img-klein-q4 · seed 42 · steps 4")
        #expect(MediaProvenanceWriter.string(m, "xmp:CreatorTool")?.hasPrefix("AntiChat ") == true)
        #expect(MediaProvenanceWriter.string(m, "antichat:model") == "img-klein-q4")
        #expect(MediaProvenanceWriter.string(m, "antichat:seed") == "42")
        #expect(MediaProvenanceWriter.string(m, "antichat:steps") == "4")
        #expect(MediaProvenanceWriter.string(m, "antichat:parent") == "ver-1")
        #expect(MediaProvenanceWriter.string(m, "antichat:operation") == "edit")
        let chunks = try #require(PNGChunks(png))
        #expect(chunks.textValue("Description") == description)
        let params = try #require(chunks.textValue("parameters"))
        #expect(params.contains("\"prompt\":\"a lighthouse at dusk"))
        #expect(params.contains("\"model\":\"img-klein-q4\"") && params.contains("\"operation\":\"edit\""))
        #expect(!params.contains("secret sd prompt"))  // sd.cpp's own text chunk is replaced
        // Only chunks were added: the pixels are the checked ones.
        #expect(try Self.pixels(png) == Self.pixels(plain))
        #expect(MediaProvenanceWriter.info(fromPNG: png)?.prompt == Self.info.prompt)
        #expect(MediaProvenanceWriter.info(fromPNG: png)?.operation == .edit)
        // AT-287 AC1: the saved sample for tools/media/check-getinfo.sh (Spotlight / Finder Get Info).
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dir = root.appending(path: "build/at/AT-287")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "saved-sample.png"))
        try MediaProvenanceWriter.writePNG(plain, info: Self.info, stripPrompt: true).write(to: dir.appending(path: "saved-sample-stripped.png"))
    }

    @Test func testStripKeepsMark() throws {
        let full = try MediaProvenanceWriter.writePNG(try Self.plainPNG(), info: Self.info, stripPrompt: false)
        for png in [try MediaProvenanceWriter.writePNG(try Self.plainPNG(), info: Self.info, stripPrompt: true),
                    try MediaProvenanceWriter.strippingPrompt(full)] {
            let m = try #require(MediaProvenanceWriter.metadata(png))
            #expect(MediaProvenanceWriter.string(m, "Iptc4xmpExt:DigitalSourceType") == MediaProvenanceWriter.digitalSourceType)
            #expect(MediaProvenanceWriter.string(m, "dc:description") == "model img-klein-q4 · seed 42 · steps 4")
            #expect(MediaProvenanceWriter.string(m, "xmp:CreatorTool")?.hasPrefix("AntiChat ") == true)
            #expect(MediaProvenanceWriter.string(m, "antichat:model") == "img-klein-q4")
            // No prompt anywhere in the file.
            #expect(png.range(of: Data("lighthouse".utf8)) == nil)
            #expect(png.range(of: Data("secret sd prompt".utf8)) == nil)
            #expect(try Self.pixels(png) == Self.pixels(full))
        }
    }

    @Test func testNotPNGThrows() {
        #expect(throws: MediaProvenanceWriter.WriteError.notPNG) {
            try MediaProvenanceWriter.writePNG(Data("nope".utf8), info: Self.info, stripPrompt: false)
        }
    }

    /// A synthetic 2 s clip (R-287 AC3 in M4; M5 re-runs it on real video): written with the metadata, read back,
    /// playable, and Quick Look renders a thumbnail.
    @Test func testMP4MarkAndPlayable() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "clip.mp4")
        try await Self.writeClip(url, info: Self.info)

        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.metadata)
        func value(_ id: AVMetadataIdentifier) async -> String? {
            guard let i = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
            return try? await i.load(.stringValue)
        }
        #expect(await value(.isoUserDataTaggedCharacteristic) == MediaProvenanceWriter.digitalSourceType)
        #expect(await value(AVMetadataIdentifier(rawValue: "uiso/dscp"))?.contains("a lighthouse at dusk") == true)
        #expect(await value(AVMetadataIdentifier(rawValue: "uiso/swre"))?.hasPrefix("AntiChat ") == true)
        let xmp = try #require(MediaProvenanceWriter.xmp(ofMP4: try Data(contentsOf: url)))
        #expect(MediaProvenanceWriter.string(xmp, "Iptc4xmpExt:DigitalSourceType") == MediaProvenanceWriter.digitalSourceType)
        #expect(MediaProvenanceWriter.string(xmp, "antichat:model") == "img-klein-q4")
        #expect(MediaProvenanceWriter.string(xmp, "antichat:seed") == "42")
        #expect(MediaProvenanceWriter.string(xmp, "antichat:operation") == "edit")
        #expect(MediaProvenanceWriter.string(xmp, "dc:description")?.contains("a lighthouse at dusk") == true)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds >= 1.9)

        // qlmanage renders a thumbnail of the clip.
        let thumbs = dir.appending(path: "thumbs")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-t", "-s", "128", "-o", thumbs.path, url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect((try FileManager.default.contentsOfDirectory(atPath: thumbs.path)).contains { $0.hasSuffix(".png") })
    }

    /// 2 s at 8 fps, 64×48 solid frames (the ScriptedImageEngine stand-in for M5's real frames).
    static func writeClip(_ url: URL, info: GenerationInfo) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        MediaProvenanceWriter.writeMP4Metadata(assetWriter: writer, info: info)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for f in 0..<16 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            let b = try #require(buffer)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), Int32(f * 12), CVPixelBufferGetDataSize(b))
            CVPixelBufferUnlockBaseAddress(b, [])
            #expect(adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 8)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 16, timescale: 8))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        try MediaProvenanceWriter.appendXMP(toMP4: url, info: info, stripPrompt: false)
    }
}
