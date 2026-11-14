// M6.T09 (R-273 AC1–AC3): `create_document` — validate (schema + semantic checks), resolve image refs, render
// (PDF: TPPDF; DOCX: docx in RenderHost; MD: as is), save as an artifact version, and answer with a one-line JSON
// summary the FileCard/ActivityLine read back (`{artifact_id, file, format, pages?, path, size, version}`) plus one
// sentence for the model. Validation problems come back as the repair text (`{"repair": true, "errors": […]}`), which
// the tool loop sends once (RepairRetry); a second failure ends as the error card (`file.createFailed`, [Try again]).
import Foundation
import PDFKit

public enum CreateDocumentTool {
    public static let name = FileOutSchemas.createDocumentName

    /// Schema problems + semantic problems (image refs must be known ids; no remote images; `revises` names a file of
    /// this chat).
    public static func problems(argumentsJSON: String, imageExists: (String) -> Bool,
                                revisesProblem: (String?) -> String? = { _ in nil }) -> [String] {
        var out = SpecValidator.problems(json: argumentsJSON, schemaJSON: FileOutSchemas.createDocumentJSON)
        guard out.isEmpty, let spec = try? decode(argumentsJSON) else { return out }
        if let p = revisesProblem(spec.revises) { out.append(p) }
        if spec.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("$.markdown: empty") }
        let declared = Set((spec.images ?? []).map(\.ref))
        for ref in declared where !imageExists(ref) {
            out.append("$.images: no attachment or file with id \"\(ref)\"")
        }
        for ref in DocumentAST.imageRefs(DocumentAST.parse(spec.markdown)) {
            if ref.hasPrefix("http://") || ref.hasPrefix("https://") {
                out.append("$.markdown: image \(ref) is a web address; only attached images (ids in `images`) can be used")
            } else if !declared.contains(ref) && !imageExists(ref) {
                out.append("$.markdown: image ref \"\(ref)\" is not in `images`")
            }
        }
        return out
    }

    /// The repair text for `problems` (R-273 AC2).
    public static func repairText(_ problems: [String]) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct R: Encodable { var repair = true; var errors: [String] }
        return (try? e.encode(R(errors: problems))).map { String(decoding: $0, as: UTF8.self) } ?? #"{"repair":true}"#
    }

    public static func decode(_ json: String) throws -> CreateDocumentSpec {
        do { return try JSONDecoder().decode(CreateDocumentSpec.self, from: Data(json.utf8)) } catch {
            throw FileOutError.invalidSpec(["$: \(error)"])
        }
    }

    /// Renders `spec` to file bytes (no model, no network, no process).
    @MainActor
    public static func render(_ spec: CreateDocumentSpec, images: [String: FileOutImage] = [:], locale: Locale = .current,
                              host: RenderHost = .shared) async throws -> Data {
        switch spec.format {
        case .pdf: try PDFRenderer.render(spec, images: images, locale: locale)
        case .docx: try await DOCXRenderer.render(spec, images: images, locale: locale, host: host)
        case .md: MarkdownWriter.render(spec)
        }
    }

    /// The whole call: decode → render → save. Throws `FileOutError` (the activity line shows it).
    @MainActor
    public static func run(argumentsJSON: String, chatID: String, messageID: String?, store: ArtifactStore,
                           host: RenderHost = .shared) async throws -> String {
        let spec = try decode(argumentsJSON)
        var images: [String: FileOutImage] = [:]
        let refs = Set((spec.images ?? []).map(\.ref) + DocumentAST.imageRefs(DocumentAST.parse(spec.markdown)))
        for ref in refs {
            if let d = store.imageData(ref: ref, chatID: chatID) {
                images[ref] = FileOutImage(data: d, alt: spec.images?.first { $0.ref == ref }?.alt)
            }
        }
        let data = try await render(spec, images: images, host: host)
        let saved = try store.save(chatID: chatID, kind: spec.format.rawValue, filename: spec.filename, data: data,
                                   specJSON: argumentsJSON, messageID: messageID, revises: spec.revises)
        let pages = spec.format == .pdf ? PDFKit.PDFDocument(data: data)?.pageCount : nil
        let chain = saved.version > 1 ? VersioningService(store: store).versions(of: saved.artifactID) : []
        return resultText(saved, format: spec.format.rawValue, pages: pages, versions: chain)
    }

    public typealias Result = FileOutResult

    public static func resultText(_ s: SavedArtifact, format: String, pages: Int?, versions: [VersionInfo] = []) -> String {
        FileOutResult.text(s, format: format, pages: pages, versions: versions)
    }

    /// The summary line of a result (FileCard / ActivityLine).
    public static func result(ofText text: String) -> Result? { FileOutResult.parse(text) }
}
