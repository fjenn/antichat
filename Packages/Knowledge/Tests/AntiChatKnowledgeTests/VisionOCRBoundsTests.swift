// M6 review #14: OCR never decodes or renders past `VisionOCR.maxPixels` on a side: a huge image is decoded through
// the thumbnailer, a huge PDF page is rendered at a capped scale.
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import AntiChatKnowledge

@Suite struct VisionOCRBoundsTests {
    @Test func hugeImageIsDecodedCapped() throws {
        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = 9000
        let ctx = try #require(CGContext(data: nil, width: side, height: side / 2, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        let url = dir.appendingPathComponent("big.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
        let (image, _) = try #require(VisionOCR.image(at: url))
        #expect(max(image.width, image.height) <= VisionOCR.maxPixels, "\(image.width)×\(image.height)")
        #expect(image.width == 2 * image.height, "aspect kept")
        let small = IntakeFixtures.url("images/upload-errors/sample.png")
        let src = try #require(CGImageSourceCreateWithURL(small as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(VisionOCR.image(at: small)?.0.width == props[kCGImagePropertyPixelWidth] as? Int, "small images keep their size")
    }

    @Test func hugePageRendersCapped() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 14_400, height: 7_200)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil); pdf.endPDFPage(); pdf.closePDF()
        let page = try #require(PDFDocument(data: data as Data)?.page(at: 0))
        let image = try #require(VisionOCR.render(page))
        #expect(max(image.width, image.height) <= VisionOCR.maxPixels, "\(image.width)×\(image.height)")
        let letter = try #require(PDFDocument(url: IntakeFixtures.url("docs/pdf/text-10p.pdf"))?.page(at: 0))
        let normal = try #require(VisionOCR.render(letter))
        #expect(Double(normal.width) / Double(letter.bounds(for: .mediaBox).width) >= 300.0 / 72.0 - 0.01, "normal pages keep ≥ 300 dpi")
    }
}
