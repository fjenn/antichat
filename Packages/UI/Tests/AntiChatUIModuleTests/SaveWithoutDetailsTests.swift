// M4 review P1-4 (R-287 AC2): "Save without prompt details" never writes the prompt. When the prompt cannot be stripped
// (here: a file that is not a PNG) the save fails and NOTHING is written at the destination; a PNG is written stripped.
import AntiChatTools
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct SaveWithoutDetailsTests {
    static func png() -> Data {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
        return out as Data
    }

    @Test @MainActor func unstrippableFileWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("save-nodetails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.mp4")
        try Data("ftyp…prompt: a secret prompt".utf8).write(to: source)
        let dest = dir.appendingPathComponent("out.mp4")
        #expect(throws: (any Error).self) { try SavePanelAccessory.write(source, to: ImageSaveChoice(url: dest, stripPrompt: true)) }
        #expect(!FileManager.default.fileExists(atPath: dest.path), "nothing written")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count == 1, "no staging file left")
    }

    @Test @MainActor func pngIsWrittenWithoutThePrompt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("save-nodetails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = GenerationInfo(prompt: "a secret prompt", model: "img-klein-q8", seed: 1, steps: 4)
        let source = dir.appendingPathComponent("image.png")
        try MediaProvenanceWriter.writePNG(Self.png(), info: info, stripPrompt: false).write(to: source)
        let dest = dir.appendingPathComponent("saved.png")
        try SavePanelAccessory.write(source, to: ImageSaveChoice(url: dest, stripPrompt: true))
        let saved = try Data(contentsOf: dest)
        #expect(MediaProvenanceWriter.info(fromPNG: saved)?.prompt == nil)
        #expect(!String(decoding: saved, as: UTF8.self).contains("a secret prompt"))
    }
}
