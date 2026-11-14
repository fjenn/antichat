// M4.T09 (R-287; P-media-09): the AI-generated mark and the generation details in every saved picture and video.
//   PNG: an XMP packet (iTXt `XML:com.adobe.xmp`) with `Iptc4xmpExt:DigitalSourceType` = trainedAlgorithmicMedia
//   (always), `dc:description` (the Get Info text), `xmp:CreatorTool` and the `antichat:` namespace (model, seed, steps,
//   parent, operation); plus PNG text chunks `Description` (the Get Info text), `Software` and `parameters` (generation
//   info JSON). `stripPrompt` ("Save without prompt details", R-287 AC2) leaves the prompt out of every field but keeps
//   the mark, the creator tool and the model id.
//   MP4 (R-287 AC3): `AVMetadataItem`s on the `AVAssetWriter` — description, software and the DigitalSourceType (an
//   MP4 keeps only ISO user data; a MOV also keeps the `mdta` DigitalSourceType and `com.antichat.generation` JSON) —
//   plus the same XMP packet as the PNG in a `uuid` box (the XMP spec's MP4 placement), `appendXMP`.
//   Export MP4 of a stored clip (M5.T12; was MP4Export): a byte copy, or with `stripPrompt` a passthrough re-mux whose
//   user data and XMP box leave the prompt out (`exportMP4`).
// The writer only ADDS chunks to the PNG the gate already checked: the image data (IHDR…IDAT…IEND) is copied byte for
// byte, so the pixels are exactly the checked ones (D-006). Earlier text chunks (sd.cpp writes the prompt into a
// `parameters` tEXt) are dropped, so a stripped file carries no prompt anywhere.
// Lives in AntiChatTools (not Engines/MediaOutput as M4.md names it): the app process saves artifacts and the UI's
// Save As rewrites files, and neither may link AntiChatEngines (architecture §3 rule 1).
import AVFoundation
import AntiChatStorage
import CoreGraphics
import Foundation
import ImageIO

/// What made a picture or a clip (R-287 AC1/AC4).
public struct GenerationInfo: Sendable, Equatable, Codable {
    /// The prompt the image model got; nil once stripped.
    public var prompt: String?
    public var model: String
    public var seed: Int64
    public var steps: Int
    /// The `artifact_version` id this one was made from (nil for a first generation).
    public var parent: String?
    public var operation: ArtifactOperation
    public var width: Int?
    public var height: Int?

    public init(prompt: String?, model: String, seed: Int64, steps: Int, parent: String? = nil,
                operation: ArtifactOperation = .generate, width: Int? = nil, height: Int? = nil) {
        self.prompt = prompt; self.model = model; self.seed = seed; self.steps = steps; self.parent = parent
        self.operation = operation; self.width = width; self.height = height
    }
}

public enum MediaProvenanceWriter {
    public static let digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
    public static let namespace = "http://antichat.app/ns/1.0/"
    static let iptcExtNamespace = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    static let xmpKeyword = "XML:com.adobe.xmp"

    public enum WriteError: Error, Equatable { case notPNG, metadata, export(String) }

    /// "AntiChat <version>" (`xmp:CreatorTool`, PNG `Software`, MP4 software).
    public static var creatorTool: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "AntiChat \(v ?? "dev")"
    }

    /// The Get Info text (R-287 AC1): "<prompt> — model <id> · seed <n> · steps <s>"; without the prompt when stripped.
    public static func getInfoText(_ info: GenerationInfo, stripPrompt: Bool) -> String {
        let details = "model \(info.model) · seed \(info.seed) · steps \(info.steps)"
        guard !stripPrompt, let p = info.prompt, !p.isEmpty else { return details }
        return "\(p) — \(details)"
    }

    /// The `parameters` / `com.antichat.generation` JSON (sorted keys; no prompt when stripped).
    public static func generationJSON(_ info: GenerationInfo, stripPrompt: Bool) -> String {
        var o: [String: Any] = ["model": info.model, "seed": info.seed, "steps": info.steps, "operation": info.operation.rawValue,
                                "digital_source_type": "trainedAlgorithmicMedia"]
        if let p = info.parent { o["parent"] = p }
        if let w = info.width { o["width"] = w }
        if let h = info.height { o["height"] = h }
        if !stripPrompt, let p = info.prompt { o["prompt"] = p }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - PNG

    /// `png` with the mark and the details added (the image chunks unchanged).
    public static func writePNG(_ png: Data, info: GenerationInfo, stripPrompt: Bool) throws -> Data {
        guard var chunks = PNGChunks(png) else { throw WriteError.notPNG }
        guard let xmp = xmpPacket(info, stripPrompt: stripPrompt) else { throw WriteError.metadata }
        chunks.removeText()
        let text = getInfoText(info, stripPrompt: stripPrompt)
        chunks.insertAfterHeader([
            PNGChunks.iTXt(xmpKeyword, xmp),
            PNGChunks.text("Description", text),
            PNGChunks.text("Software", creatorTool),
            PNGChunks.text("parameters", generationJSON(info, stripPrompt: stripPrompt)),
        ])
        return chunks.data
    }

    /// The same file without prompt details (Save without prompt details): its own marks re-written with `stripPrompt`.
    /// A PNG that carries no AntiChat details still gets the mark (model "unknown").
    public static func strippingPrompt(_ png: Data) throws -> Data {
        let info = self.info(fromPNG: png) ?? GenerationInfo(prompt: nil, model: "unknown", seed: 0, steps: 0)
        return try writePNG(png, info: info, stripPrompt: true)
    }

    /// The generation details a PNG written by `writePNG` carries (nil when it has none).
    public static func info(fromPNG png: Data) -> GenerationInfo? {
        guard let m = metadata(png), let model = string(m, "antichat:model") else { return nil }
        let prompt = PNGChunks(png)?.textValue("parameters").flatMap { s -> String? in
            guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return nil }
            return o["prompt"] as? String
        }
        return GenerationInfo(prompt: prompt, model: model, seed: Int64(string(m, "antichat:seed") ?? "") ?? 0,
                              steps: Int(string(m, "antichat:steps") ?? "") ?? 0, parent: string(m, "antichat:parent"),
                              operation: ArtifactOperation(rawValue: string(m, "antichat:operation") ?? "") ?? .generate,
                              width: nil, height: nil)
    }

    /// The XMP of an image file (ImageIO's reader: what Spotlight and other apps see).
    public static func metadata(_ data: Data) -> CGImageMetadata? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyMetadataAtIndex(src, 0, nil)
    }

    /// One XMP value by `prefix:name` path.
    public static func string(_ m: CGImageMetadata, _ path: String) -> String? {
        // A language alternative (dc:description) reads as its x-default item.
        (CGImageMetadataCopyStringValueWithPath(m, nil, path as CFString) as String?)
            ?? (CGImageMetadataCopyStringValueWithPath(m, nil, "\(path)[x-default]" as CFString) as String?)
    }

    static func xmpPacket(_ info: GenerationInfo, stripPrompt: Bool) -> Data? {
        let m = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(m, namespace as CFString, "antichat" as CFString, nil) else { return nil }
        func set(_ ns: String, _ prefix: String, _ name: String, _ value: String) -> Bool {
            guard let tag = CGImageMetadataTagCreate(ns as CFString, prefix as CFString, name as CFString, .string,
                                                     value as CFString) else { return false }
            return CGImageMetadataSetTagWithPath(m, nil, "\(prefix):\(name)" as CFString, tag)
        }
        var ok = set(iptcExtNamespace, "Iptc4xmpExt", "DigitalSourceType", digitalSourceType)
        // dc:description is a language alternative: ImageIO builds the rdf:Alt from the `[x-default]` path.
        ok = ok && CGImageMetadataSetValueWithPath(m, nil, "dc:description[x-default]" as CFString,
                                                   getInfoText(info, stripPrompt: stripPrompt) as CFString)
        ok = ok && set(kCGImageMetadataNamespaceXMPBasic as String, "xmp", "CreatorTool", creatorTool)
        ok = ok && set(namespace, "antichat", "model", info.model)
        ok = ok && set(namespace, "antichat", "seed", "\(info.seed)")
        ok = ok && set(namespace, "antichat", "steps", "\(info.steps)")
        ok = ok && set(namespace, "antichat", "operation", info.operation.rawValue)
        if let p = info.parent { ok = ok && set(namespace, "antichat", "parent", p) }
        guard ok else { return nil }
        return CGImageMetadataCreateXMPData(m, nil) as Data?
    }

    // MARK: - MP4

    /// The XMP box of an MP4 (ISO 14496-12 `uuid` box, the XMP spec's MP4 placement).
    static let xmpUUID: [UInt8] = [0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC]
    /// XMP paths that can carry the prompt (dropped when stripping a clip; `dc:description` is rewritten without it).
    static let promptPaths = ["antichat:prompt", "antichat:negativePrompt", "photoshop:Headline", "dc:title"]

    /// The metadata items of a generated clip (R-287 AC3). An MP4 writer keeps only the ISO user-data items
    /// (description `dscp`, software `swre`, tagged characteristic `tagc` = the DigitalSourceType); a MOV keeps them
    /// all, including the `mdta` keys `com.iptc.DigitalSourceType` and `com.antichat.generation`. For MP4 the full
    /// details go into the file's XMP box too (`appendXMP`).
    public static func mp4Metadata(_ info: GenerationInfo, stripPrompt: Bool) -> [AVMetadataItem] {
        func mdta(_ key: String, _ value: String) -> AVMetadataItem {
            userData(AVMetadataItem.identifier(forKey: key as NSString, keySpace: .quickTimeMetadata)!, value)
        }
        return [
            userData(.commonIdentifierDescription, getInfoText(info, stripPrompt: stripPrompt)),
            userData(.commonIdentifierSoftware, creatorTool),
            userData(.isoUserDataTaggedCharacteristic, digitalSourceType),
            mdta("com.iptc.DigitalSourceType", digitalSourceType),
            mdta("com.antichat.generation", generationJSON(info, stripPrompt: stripPrompt)),
        ]
    }

    /// The ISO user-data items a stripped re-mux keeps (M5.T12): software (always) and the description (when there is one).
    static func mp4UserData(summary: String?) -> [AVMetadataItem] {
        var items = [userData(.commonIdentifierSoftware, "AntiChat")]
        if let summary { items.append(userData(.commonIdentifierDescription, summary)) }
        return items
    }

    private static func userData(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let i = AVMutableMetadataItem()
        i.identifier = id
        i.value = value as NSString
        i.dataType = kCMMetadataBaseDataType_UTF8 as String
        i.extendedLanguageTag = "und"
        return i.copy() as! AVMetadataItem
    }

    /// Sets the clip's metadata on `assetWriter` (before `startWriting`); after `finishWriting` of an MP4, call
    /// `appendXMP(toMP4:info:stripPrompt:)`.
    public static func writeMP4Metadata(assetWriter: AVAssetWriter, info: GenerationInfo, stripPrompt: Bool = false) {
        assetWriter.metadata = mp4Metadata(info, stripPrompt: stripPrompt)
    }

    /// Appends the XMP packet (the PNG's fields: DigitalSourceType, description, creator tool, `antichat:`) as a
    /// top-level `uuid` box of a finished MP4.
    public static func appendXMP(toMP4 url: URL, info: GenerationInfo, stripPrompt: Bool) throws {
        guard let xmp = xmpPacket(info, stripPrompt: stripPrompt) else { throw WriteError.metadata }
        try appendXMPBox(xmp, to: url)
    }

    /// Appends `xmp` as a top-level `uuid` box (valid anywhere at the top level of an ISO BMFF file).
    static func appendXMPBox(_ xmp: Data, to url: URL) throws {
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

    /// The XMP of an MP4's top-level `uuid` box (nil when it has none).
    public static func xmp(ofMP4 data: Data) -> CGImageMetadata? {
        xmpBox(in: data).flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
    }

    /// The raw XMP packet of an MP4 file (top-level `uuid` box), or nil.
    public static func xmpData(ofMP4 url: URL) throws -> Data? {
        xmpBox(in: try Data(contentsOf: url, options: .alwaysMapped))
    }

    /// Walks the top-level boxes; every size is checked against the bytes left (M5.T14 review P2: a 64-bit size can
    /// never overflow the offset).
    static func xmpBox(in d: Data) -> Data? {
        let base = d.startIndex
        var o = 0
        while o + 8 <= d.count {
            var raw = d[base + o..<base + o + 4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: d[base + o + 4..<base + o + 8], as: UTF8.self)
            if raw == 1, o + 16 <= d.count { raw = d[base + o + 8..<base + o + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            if raw == 0 { raw = UInt64(d.count - o) }  // to the end of the file
            guard raw <= UInt64(d.count - o) else { return nil }
            let size = Int(raw)
            guard size >= 8 else { return nil }
            if type == "uuid", size >= 24, Array(d[base + o + 8..<base + o + 24]) == xmpUUID {
                return d.subdata(in: base + o + 24..<base + o + size)
            }
            o += size
        }
        return nil
    }

    // MARK: - MP4 export (M5.T12 step 3; R-045 AC2, R-287 AC2)

    /// Export MP4 of a stored clip: writes `source` to `destination`, replacing a file there. The stored file already
    /// carries the mark (MP4Encoder: `dscp` / `swre` user data and the XMP box), so a plain export is a byte copy.
    /// `stripPrompt` ("Save without prompt details") re-muxes it with `AVAssetExportSession` passthrough (no re-encode:
    /// the gate-checked frames are untouched) under metadata without the prompt, and appends the XMP packet again
    /// without the prompt: the mark, the creator tool, the model id, seed, steps, operation and parent stay. The write
    /// is atomic (staged next to the destination, then moved).
    public static func exportMP4(_ source: URL, to destination: URL, stripPrompt: Bool) async throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).antichat-\(UUID().uuidString).mp4")
        defer { try? fm.removeItem(at: staging) }
        if stripPrompt {
            try await strippedMP4(source, to: staging)
        } else {
            try fm.copyItem(at: source, to: staging)
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// Passthrough re-mux with the prompt left out of every metadata field.
    static func strippedMP4(_ source: URL, to out: URL) async throws {
        let xmp = try xmpData(ofMP4: source)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw WriteError.export("no passthrough session")
        }
        session.metadata = mp4UserData(summary: strippedSummary(xmp.map(fields) ?? [:]))
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            throw WriteError.export("\(error)")
        }
        if let xmp {
            guard let clean = strippingPrompt(xmp: xmp) else { throw WriteError.metadata }
            try appendXMPBox(clean, to: out)
        }
    }

    /// The Get-Info line without the prompt: "model <id> · seed <n> · steps <s>" (getInfoText, stripped), from the
    /// fields of a clip's XMP.
    static func strippedSummary(_ f: [String: String]) -> String? {
        guard let model = f["antichat:model"] else { return nil }
        var parts = ["model \(model)"]
        if let s = f["antichat:seed"] { parts.append("seed \(s)") }
        if let s = f["antichat:steps"] { parts.append("steps \(s)") }
        return parts.joined(separator: " · ")
    }

    /// A clip's XMP packet without the prompt: `dc:description` becomes the stripped summary, prompt fields go, the
    /// rest (the AI mark first of all) is kept. Nil when the packet cannot be parsed or rewritten.
    public static func strippingPrompt(xmp: Data) -> Data? {
        guard let parsed = CGImageMetadataCreateFromXMPData(xmp as CFData),
              let m = CGImageMetadataCreateMutableCopy(parsed) else { return nil }
        let f = fields(xmp)
        var err: Unmanaged<CFError>?
        _ = CGImageMetadataRegisterNamespaceForPrefix(m, namespace as CFString, "antichat" as CFString, &err)
        for path in promptPaths + ["dc:description"] { CGImageMetadataRemoveTagWithPath(m, nil, path as CFString) }
        if let s = strippedSummary(f), !CGImageMetadataSetValueWithPath(m, nil, "dc:description" as CFString, s as CFString) {
            return nil
        }
        if f["Iptc4xmpExt:DigitalSourceType"] == nil,
           !CGImageMetadataSetValueWithPath(m, nil, "Iptc4xmpExt:DigitalSourceType" as CFString, digitalSourceType as CFString) {
            return nil
        }
        return CGImageMetadataCreateXMPData(m, nil) as Data?
    }

    /// `prefix:name` → string value of every simple tag in an XMP packet (tests, Get-Info checks).
    public static func fields(_ xmp: Data) -> [String: String] {
        guard let m = CGImageMetadataCreateFromXMPData(xmp as CFData) else { return [:] }
        var out: [String: String] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(m, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            if let v = CGImageMetadataTagCopyValue(tag) as? String { out[path as String] = v }
            return true
        }
        if let d = CGImageMetadataCopyStringValueWithPath(m, nil, "dc:description" as CFString) { out["dc:description"] = d as String }
        return out
    }
}

/// A PNG as its chunk list (signature, then length · type · data · CRC per chunk).
struct PNGChunks {
    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    struct Chunk { var type: String; var data: Data }
    var chunks: [Chunk]

    init?(_ png: Data) {
        let bytes = [UInt8](png)
        guard bytes.count > 8, Data(bytes[0..<8]) == Self.signature else { return nil }
        var i = 8
        var out: [Chunk] = []
        while i + 12 <= bytes.count {
            let len = Int(UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]))
            guard i + 12 + len <= bytes.count else { return nil }
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            out.append(Chunk(type: type, data: Data(bytes[(i + 8)..<(i + 8 + len)])))
            i += 12 + len
            if type == "IEND" { break }
        }
        guard out.first?.type == "IHDR", out.last?.type == "IEND" else { return nil }
        chunks = out
    }

    var data: Data {
        var d = Self.signature
        for c in chunks {
            var len = UInt32(c.data.count).bigEndian
            d.append(Data(bytes: &len, count: 4))
            let typeAndData = Data(c.type.utf8) + c.data
            d.append(typeAndData)
            var crc = Self.crc32(typeAndData).bigEndian
            d.append(Data(bytes: &crc, count: 4))
        }
        return d
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (ISO 3309, PNG spec §5.5).
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Drops every text chunk (tEXt, zTXt, iTXt — XMP included).
    mutating func removeText() { chunks.removeAll { ["tEXt", "zTXt", "iTXt"].contains($0.type) } }

    mutating func insertAfterHeader(_ new: [Chunk]) { chunks.insert(contentsOf: new, at: 1) }

    /// tEXt when the text is Latin-1, else iTXt (UTF-8).
    static func text(_ keyword: String, _ value: String) -> Chunk {
        if let latin = value.data(using: .isoLatin1) { return Chunk(type: "tEXt", data: Data(keyword.utf8) + Data([0]) + latin) }
        return iTXt(keyword, Data(value.utf8))
    }

    static func iTXt(_ keyword: String, _ value: Data) -> Chunk {
        // keyword \0 compression-flag(0) method(0) language-tag \0 translated-keyword \0 text
        Chunk(type: "iTXt", data: Data(keyword.utf8) + Data([0, 0, 0, 0, 0]) + value)
    }

    /// The text of a tEXt / iTXt chunk with `keyword` (uncompressed only; ours never are).
    func textValue(_ keyword: String) -> String? {
        for c in chunks where c.type == "tEXt" || c.type == "iTXt" {
            let b = [UInt8](c.data)
            guard let z = b.firstIndex(of: 0), String(decoding: b[..<z], as: UTF8.self) == keyword else { continue }
            if c.type == "tEXt" { return String(data: Data(b[(z + 1)...]), encoding: .isoLatin1) }
            // iTXt: skip flag, method, language tag \0, translated keyword \0.
            var i = z + 3
            guard b.count > i, b[z + 1] == 0 else { continue }
            guard let l = b[i...].firstIndex(of: 0) else { continue }
            i = l + 1
            guard let t = b[i...].firstIndex(of: 0) else { continue }
            return String(decoding: b[(t + 1)...], as: UTF8.self)
        }
        return nil
    }
}
