// M6.T04 step 2 (R-271 AC1/AC3; P-files-tools-02): one page image → Markdown. macOS 26 Vision
// `RecognizeDocumentsRequest` gives the document's structure: paragraphs, lists and tables (tables become Markdown
// tables, a spanned cell repeated into every cell it spans, first row = header), emitted top to bottom; paragraphs
// inside a table / list region are not repeated. If the request throws or finds no text: `VNRecognizeTextRequest`
// `.accurate` with language correction, languages = preferred + en-US (tables are lost on that path). `.fast` (T0 above
// 50 pages, step 4) goes straight to the text request at `.fast`. Rendering: the PDF page at max(2, 300/72)× its
// media box (≥ 300 dpi effective for letter/A4). Never on the main actor (callers are the intake actor / OCRQueue).
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

public struct VisionOCR: Sendable {
    public enum Level: String, Sendable { case accurate, fast }

    public init() {}

    /// Scale for a PDF page: ≥ 2× and ≥ 300 dpi effective.
    public static let pageScale: CGFloat = max(2, 300.0 / 72.0)

    /// The largest side OCR decodes or renders, in pixels (M6 review #14: a huge page or image never allocates
    /// gigabytes; 6000 px keeps a Letter/A4 page at ≥ 300 dpi with room to spare).
    public static let maxPixels = 6000

    /// The page rendered on white at `scale`× its media box (grayscale is enough for OCR), the larger side capped at
    /// `maxPixels`.
    public static func render(_ page: PDFPage, scale: CGFloat = pageScale) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let longest = max(box.width, box.height)
        let scale = longest > 0 ? min(scale, CGFloat(maxPixels) / longest) : scale
        let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceGray(),
                                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// An image file's first frame, EXIF orientation applied by Vision; decoded through ImageIO's thumbnailer at most
    /// `maxPixels` on the larger side (a small file can declare a 40000² image).
    public static func image(at url: URL) -> (CGImage, CGImagePropertyOrientation)? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: false,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (img, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    /// Markdown of one image (document request, then the text-request fallback).
    public func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation = .up,
                          level: Level = .accurate) async -> String {
        if level == .accurate, let md = try? await document(image, orientation: orientation),
           !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return md
        }
        return (try? Self.text(image, orientation: orientation, level: level)) ?? ""
    }

    /// `RecognizeDocumentsRequest` → Markdown.
    func document(_ image: CGImage, orientation: CGImagePropertyOrientation) async throws -> String {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        let observations = try await request.perform(on: image, orientation: orientation)
        return observations.map { Self.markdown($0.document) }.joined(separator: "\n\n")
    }

    /// Recognition languages: the user's preferred ones + en-US.
    static var languages: [String] {
        var out: [String] = []
        for l in Locale.preferredLanguages + ["en-US"] where !out.contains(l) { out.append(l) }
        return out
    }

    /// The `VNRecognizeTextRequest` path: lines top to bottom.
    static func text(_ image: CGImage, orientation: CGImagePropertyOrientation, level: Level) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level == .fast ? .fast : .accurate
        req.usesLanguageCorrection = true
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let langs = languages.filter { supported.contains($0) }
        if !langs.isEmpty { req.recognitionLanguages = langs }
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([req])
        let obs = (req.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: structure → Markdown

    struct Block {
        var top: CGFloat
        var markdown: String
    }

    static func rect(_ region: NormalizedRegion) -> CGRect { region.normalizedPath.boundingBox }

    static func markdown(_ c: DocumentObservation.Container) -> String {
        var blocks: [Block] = []
        var taken: [CGRect] = []
        for t in c.tables {
            let r = rect(t.boundingRegion)
            taken.append(r)
            blocks.append(Block(top: r.maxY, markdown: table(t)))
        }
        for l in c.lists {
            let r = rect(l.boundingRegion)
            taken.append(r)
            let items = l.items.map { "- " + clean($0.itemString) }.filter { $0.count > 2 }
            if !items.isEmpty { blocks.append(Block(top: r.maxY, markdown: items.joined(separator: "\n"))) }
        }
        let title = c.title.map { clean($0.transcript) }
        if let t = c.title, let title, !title.isEmpty {
            blocks.append(Block(top: rect(t.boundingRegion).maxY, markdown: "# " + title))
        }
        for p in c.paragraphs {
            let r = rect(p.boundingRegion)
            let mid = CGPoint(x: r.midX, y: r.midY)
            if taken.contains(where: { $0.insetBy(dx: -0.005, dy: -0.005).contains(mid) }) { continue }
            let s = clean(p.transcript)
            if s.isEmpty || s == title { continue }
            blocks.append(Block(top: r.maxY, markdown: s))
        }
        if blocks.isEmpty { return clean(c.text.transcript) }
        return blocks.sorted { $0.top > $1.top }.map(\.markdown).joined(separator: "\n\n")
    }

    /// A Vision table as a Markdown table; a cell spanning rows/columns fills each of them.
    static func table(_ t: DocumentObservation.Container.Table) -> String {
        let cells = t.rows.flatMap { $0 }
        let nRows = (cells.map(\.rowRange.upperBound).max() ?? -1) + 1
        let nCols = (cells.map(\.columnRange.upperBound).max() ?? -1) + 1
        guard nRows > 0, nCols > 0 else { return "" }
        var grid = Array(repeating: Array(repeating: "", count: nCols), count: nRows)
        for cell in cells {
            let text = clean(cell.content.text.transcript).replacingOccurrences(of: "|", with: "\\|")
            for r in cell.rowRange where r < nRows { for col in cell.columnRange where col < nCols { grid[r][col] = text } }
        }
        func line(_ r: [String]) -> String { "| " + r.joined(separator: " | ") + " |" }
        return ([line(grid[0]), "|" + Array(repeating: " --- |", count: nCols).joined()] + grid.dropFirst().map(line))
            .joined(separator: "\n")
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
