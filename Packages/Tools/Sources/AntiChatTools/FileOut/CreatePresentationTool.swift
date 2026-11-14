// M6.T11 (R-275 AC1, P-files-tools-05): `create_presentation` — a 1–30 slide deck (layouts title / bullets / image /
// title_bullets_image, ≤ 8 bullets, speaker notes, images from attachment / artifact ids) in one of four themes
// (Resources/pptx-themes: clean, dusk, paper, bold = slide masters with fonts, colours, accent bar, slide numbers).
// Rendered by PptxGenJS 4.0.1 in RenderHost (`bridge-pptx.js`); > 30 slides, > 8 bullets, a bad layout / theme or an
// unknown image id → the repair turn. A missing title or image is tolerated (empty title; image layouts without
// image_ref keep their text) — T1 models often leave them out.
import AppKit
import Foundation

public enum PresentationSchemas {
    public static let name = "create_presentation"
    public static let description = """
        Create a downloadable slide deck (PowerPoint .pptx; opens in Keynote and PowerPoint). 1–30 slides; layouts: title, \
        bullets, image, title_bullets_image; up to 8 short bullets per slide; optional speaker notes; images by the id of an \
        attached picture (image_ref). Themes: clean (default), dusk, paper, bold. To change a deck you made earlier, pass its artifact_id as \
        `revises`. Runs on this Mac; nothing is uploaded.
        """
    public static let json = #"{"type":"object","properties":{"filename":{"type":"string","minLength":1,"maxLength":200},"theme":{"type":"string","enum":["clean","dusk","paper","bold"]},"slides":{"type":"array","minItems":1,"maxItems":30,"items":{"type":"object","properties":{"layout":{"type":"string","enum":["title","bullets","image","title_bullets_image"]},"title":{"type":"string"},"subtitle":{"type":"string"},"bullets":{"type":"array","maxItems":8,"items":{"type":"string"}},"image_ref":{"type":"string","description":"The id of an attached picture (listed in the chat context); leave out when none is attached."},"notes":{"type":"string"}},"required":["layout"],"additionalProperties":false}},"revises":{"type":"string","description":"artifact_id of a deck made earlier in this chat that this replaces with a new version"}},"required":["filename","slides"],"additionalProperties":false}"#
}

public struct PresentationSpec: Codable, Sendable, Equatable {
    public struct Slide: Codable, Sendable, Equatable {
        public var layout: String
        public var title: String
        enum CodingKeys: String, CodingKey { case layout, title, subtitle, bullets, image_ref, notes }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            layout = try c.decode(String.self, forKey: .layout)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""  // a slide without a title is fine
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            bullets = try c.decodeIfPresent([String].self, forKey: .bullets)
            image_ref = try c.decodeIfPresent(String.self, forKey: .image_ref)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
        }
        public var subtitle: String?
        public var bullets: [String]?
        public var image_ref: String?
        public var notes: String?
        public init(layout: String, title: String, subtitle: String? = nil, bullets: [String]? = nil, image_ref: String? = nil,
                    notes: String? = nil) {
            self.layout = layout; self.title = title; self.subtitle = subtitle; self.bullets = bullets
            self.image_ref = image_ref; self.notes = notes
        }
    }
    public var filename: String
    public var theme: String?
    public var slides: [Slide]
    public var revises: String?

    public var outputName: String {
        let base = (filename as NSString).pathExtension.lowercased() == "pptx" ? (filename as NSString).deletingPathExtension : filename
        return FileOutNames.filename(title: base, ext: "pptx")
    }

    public static let themes = ["clean", "dusk", "paper", "bold"]
}

public enum CreatePresentationTool {
    public static let name = PresentationSchemas.name

    public static func problems(argumentsJSON: String, imageExists: (String) -> Bool,
                                revisesProblem: (String?) -> String? = { _ in nil }) -> [String] {
        var out = SpecValidator.problems(json: argumentsJSON, schemaJSON: PresentationSchemas.json)
        guard out.isEmpty, let spec = try? decode(argumentsJSON) else { return out }
        if let p = revisesProblem(spec.revises) { out.append(p) }
        for (i, s) in spec.slides.enumerated() {
            if let ref = s.image_ref, !imageExists(ref) { out.append("$.slides[\(i)].image_ref: no attachment or file with id \"\(ref)\"") }
        }
        return out
    }

    public static func decode(_ json: String) throws -> PresentationSpec {
        do { return try JSONDecoder().decode(PresentationSpec.self, from: Data(json.utf8)) } catch {
            throw FileOutError.invalidSpec(["$: \(error)"])
        }
    }

    /// The bundled theme (fonts, colours) as JSON.
    static func theme(_ name: String) throws -> [String: String] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "pptx-themes"),
              let t = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) else {
            throw FileOutError.render("missing theme \(name)")
        }
        return t
    }

    struct Payload: Encodable {
        struct Img: Encodable { var base64: String; var mime: String; var width: Int; var height: Int; var alt: String? }
        var title: String
        var theme: [String: String]
        var slides: [PresentationSpec.Slide]
        var images: [String: Img]
    }

    @MainActor
    public static func render(_ spec: PresentationSpec, images: [String: FileOutImage] = [:], host: RenderHost = .shared) async throws -> Data {
        var imgs: [String: Payload.Img] = [:]
        for (ref, img) in DOCXRenderer.normalized(images) {
            guard let ns = NSImage(data: img.data) else { continue }
            let rep = ns.representations.first
            let type = DOCXRenderer.imageType(img.data)
            imgs[ref] = Payload.Img(base64: img.data.base64EncodedString(), mime: type == "jpg" ? "image/jpeg" : "image/\(type)",
                                    width: max(rep?.pixelsWide ?? Int(ns.size.width), 1), height: max(rep?.pixelsHigh ?? Int(ns.size.height), 1),
                                    alt: img.alt)
        }
        let p = Payload(title: (spec.outputName as NSString).deletingPathExtension, theme: try theme(spec.theme ?? "clean"),
                        slides: spec.slides, images: imgs)
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        do {
            return try await host.callData("return await AntiChatRender.pptx(payload);",
                                           payload: String(decoding: try e.encode(p), as: UTF8.self))
        } catch {
            throw FileOutError.render("\(error)")
        }
    }

    @MainActor
    public static func run(argumentsJSON: String, chatID: String, messageID: String?, store: ArtifactStore,
                           host: RenderHost = .shared) async throws -> String {
        let spec = try decode(argumentsJSON)
        var images: [String: FileOutImage] = [:]
        for ref in Set(spec.slides.compactMap(\.image_ref)) {
            if let d = store.imageData(ref: ref, chatID: chatID) { images[ref] = FileOutImage(data: d) }
        }
        let data = try await render(spec, images: images, host: host)
        let saved = try store.save(chatID: chatID, kind: "pptx", filename: spec.outputName, data: data, specJSON: argumentsJSON,
                                   messageID: messageID, revises: spec.revises)
        let chain = saved.version > 1 ? VersioningService(store: store).versions(of: saved.artifactID) : []
        return FileOutResult.text(saved, format: "pptx", pages: spec.slides.count, versions: chain)
    }
}
