// M4.T15 step 3 (R-034 AC1; P-media-08 residual custom, mask bitmap after Dunebru/erase@c1ee979, MIT — reference
// only): the Erase brush. Strokes are kept in normalised picture coordinates (0…1, top-left origin) so they survive
// any window size; `render` draws them as round-capped soft lines into an 8-bit mask at the picture's pixel size
// (white = erase), feathered 4 px (two box-blur passes ≈ a 4 px Gaussian edge), optionally inverted.
import CoreGraphics
import Foundation
import ImageIO

public struct MaskStroke: Sendable, Equatable {
    /// Normalised points (x, y in 0…1 of the picture, top-left origin).
    public var points: [CGPoint]
    /// Brush radius as a fraction of the picture's longer side.
    public var radius: CGFloat

    public init(points: [CGPoint], radius: CGFloat) {
        self.points = points
        self.radius = radius
    }
}

public enum MaskBrush {
    public static let feather = 4
    /// Brush radius choices (fraction of the longer side): small, medium, large.
    public static let radii: [CGFloat] = [0.015, 0.03, 0.06]

    /// The 8-bit mask of `strokes` at `width`×`height` (255 = erase).
    public static func render(_ strokes: [MaskStroke], width: Int, height: Int, feather: Int = feather, invert: Bool = false) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: width * height)
        let long = CGFloat(max(width, height))
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Top-left origin like the strokes.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for s in strokes where !s.points.isEmpty {
                let r = max(1, s.radius * long)
                let pts = s.points.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
                if pts.count == 1 {
                    ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r))
                } else {
                    ctx.setLineWidth(2 * r)
                    ctx.beginPath()
                    ctx.addLines(between: pts)
                    ctx.strokePath()
                }
            }
        }
        if feather > 0 {
            let half = max(1, feather / 2)
            px = boxBlur(boxBlur(px, width: width, height: height, radius: half), width: width, height: height, radius: half)
        }
        if invert { px = px.map { 255 - $0 } }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG bytes of the mask.
    public static func png(_ strokes: [MaskStroke], width: Int, height: Int, invert: Bool = false) -> Data? {
        guard let img = render(strokes, width: width, height: height, invert: invert) else { return nil }
        let out = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, img, nil)
        return CGImageDestinationFinalize(d) ? out as Data : nil
    }

    /// Separable box blur (edges clamp).
    static func boxBlur(_ src: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var tmp = [UInt8](repeating: 0, count: src.count), out = tmp
        let n = 2 * radius + 1
        for y in 0..<height {
            var sum = 0
            for k in -radius...radius { sum += Int(src[y * width + min(width - 1, max(0, k))]) }
            for x in 0..<width {
                tmp[y * width + x] = UInt8(sum / n)
                sum += Int(src[y * width + min(width - 1, x + radius + 1)]) - Int(src[y * width + max(0, x - radius)])
            }
        }
        for x in 0..<width {
            var sum = 0
            for k in -radius...radius { sum += Int(tmp[min(height - 1, max(0, k)) * width + x]) }
            for y in 0..<height {
                out[y * width + x] = UInt8(sum / n)
                sum += Int(tmp[min(height - 1, y + radius + 1) * width + x]) - Int(tmp[max(0, y - radius) * width + x])
            }
        }
        return out
    }
}
