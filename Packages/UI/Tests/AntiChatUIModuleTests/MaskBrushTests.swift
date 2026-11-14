// M4.T15 step 3 (R-034): the Erase brush → an 8-bit mask at the picture's pixel size: strokes in normalised
// coordinates (top-left origin), white = erase, a soft 4 px feather, invert; the fit rect of the brush canvas.
import CoreGraphics
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct MaskBrushTests {
    static func pixels(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: img.width * img.height)
        px.withUnsafeMutableBytes { b in
            let ctx = CGContext(data: b.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return px
    }

    @Test func strokeBecomesAFeatheredMask() throws {
        // A dot in the top-left quarter of a 200×100 picture, radius 0.05 × 200 = 10 px.
        let img = try #require(MaskBrush.render([MaskStroke(points: [CGPoint(x: 0.25, y: 0.25)], radius: 0.05)], width: 200, height: 100))
        #expect(img.width == 200 && img.height == 100)
        let px = Self.pixels(img)
        #expect(px[25 * 200 + 50] == 255, "centre is fully erased")
        #expect(px[75 * 200 + 150] == 0, "far away untouched")
        // The edge is soft (feather): some pixel just outside the radius is partly set.
        let edge = (0..<6).map { px[25 * 200 + 50 + 10 + $0] }
        #expect(edge.contains { $0 > 0 && $0 < 255 })
        let inv = Self.pixels(try #require(MaskBrush.render([MaskStroke(points: [CGPoint(x: 0.25, y: 0.25)], radius: 0.05)],
                                                            width: 200, height: 100, invert: true)))
        #expect(inv[25 * 200 + 50] == 0 && inv[75 * 200 + 150] == 255)
        #expect(MaskBrush.png([], width: 10, height: 10) != nil)
    }

    @Test func canvasFitsThePicture() {
        let r = MaskCanvas.fitted(CGSize(width: 200, height: 100), in: CGSize(width: 400, height: 400))
        #expect(r == CGRect(x: 0, y: 100, width: 400, height: 200))
    }
}
