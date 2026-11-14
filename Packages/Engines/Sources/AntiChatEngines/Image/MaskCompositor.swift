// M4.T15 step 3 (R-034 AC4; P-media-08 residual custom): a mask edit's engine output is composited onto its source:
// `out = mask_dilated(8 px) ? engine : source`. Every pixel outside the dilated mask is the source pixel, byte for
// byte, so the mean difference outside it is 0 (bar: ≤ 1/255). The mask is 8-bit (MaskBrush: white = change, soft
// 4 px feather); any non-zero pixel counts as inside before the dilation. Runs in the helper BEFORE the result goes to
// `MediaJobOutputs.result`, so the gate checks exactly the composited picture that is written and shown.
// (Lives in Engines, not UI/ImageEditor as M4.md lists it: the composite must exist before the gate, which is helper
// side; the app never links Engines, architecture §3.)
import CoreGraphics
import Foundation
import ImageIO

public enum MaskCompositor {
    public static let dilation = 8
    /// The soft edge (px) outside the dilated mask where engine and source blend (M4 review round 2: a masked edit
    /// shows no seam). Beyond `dilation + feather` every pixel is the source, byte for byte.
    public static let feather = 4

    /// RGBA8 pixels of `image` drawn at `width`×`height` (premultiplied last; sRGB).
    public static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return px
    }

    /// 8-bit gray pixels of `image` at `width`×`height`.
    public static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return px
    }

    /// Binary mask (255 = inside) of every pixel within `radius` (square window) of a non-zero mask pixel.
    public static func dilated(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var bin = mask.map { $0 > 0 ? UInt8(255) : 0 }
        guard radius > 0 else { return bin }
        // Separable max filter: rows, then columns (prefix counts keep it O(w·h)).
        var tmp = [UInt8](repeating: 0, count: bin.count)
        for y in 0..<height {
            var count = [Int](repeating: 0, count: width + 1)
            for x in 0..<width { count[x + 1] = count[x] + (bin[y * width + x] > 0 ? 1 : 0) }
            for x in 0..<width {
                let a = max(0, x - radius), b = min(width, x + radius + 1)
                tmp[y * width + x] = count[b] - count[a] > 0 ? 255 : 0
            }
        }
        for x in 0..<width {
            var count = [Int](repeating: 0, count: height + 1)
            for y in 0..<height { count[y + 1] = count[y] + (tmp[y * width + x] > 0 ? 1 : 0) }
            for y in 0..<height {
                let a = max(0, y - radius), b = min(height, y + radius + 1)
                bin[y * width + x] = count[b] - count[a] > 0 ? 255 : 0
            }
        }
        return bin
    }

    /// The composite at the SOURCE's size (the engine output is resampled to it when its size differs): the engine
    /// inside the dilated mask, a `feather`-px blend just outside it, the source's exact bytes everywhere else.
    public static func composite(source: CGImage, engine: CGImage, mask: CGImage, dilate: Int = dilation,
                                 feather: Int = feather) -> CGImage? {
        let w = source.width, h = source.height
        let src = rgba(source, width: w, height: h)
        let eng = rgba(engine, width: w, height: h)
        let alpha = blendAlpha(gray(mask, width: w, height: h), width: w, height: h, dilate: dilate, feather: feather)
        var out = src
        for i in 0..<(w * h) where alpha[i] > 0 {
            let a = Int(alpha[i])
            for c in 0..<4 {
                let s = Int(src[i * 4 + c]), e = Int(eng[i * 4 + c])
                out[i * 4 + c] = UInt8((e * a + s * (255 - a) + 127) / 255)
            }
        }
        return image(rgba: out, width: w, height: h)
    }

    /// 255 inside the dilated mask, falling linearly to 0 over `feather` px outside it (Chebyshev distance), 0 beyond.
    public static func blendAlpha(_ mask: [UInt8], width: Int, height: Int, dilate: Int, feather: Int) -> [UInt8] {
        let core = dilated(mask, width: width, height: height, radius: dilate)
        guard feather > 0 else { return core }
        var alpha = core
        for k in 1...feather {
            let ring = dilated(mask, width: width, height: height, radius: dilate + k)
            let v = UInt8(255 * (feather + 1 - k) / (feather + 1))
            for i in 0..<alpha.count where alpha[i] == 0 && ring[i] > 0 { alpha[i] = v }
        }
        return alpha
    }

    /// Max absolute per-channel difference (RGB) outside the dilated + feathered band.
    public static func maxAbsDiffOutside(_ a: CGImage, _ b: CGImage, mask: CGImage, dilate: Int = dilation + feather) -> Int {
        let w = a.width, h = a.height
        let pa = rgba(a, width: w, height: h), pb = rgba(b, width: w, height: h)
        let inside = dilated(gray(mask, width: w, height: h), width: w, height: h, radius: dilate)
        var m = 0
        for i in 0..<(w * h) where inside[i] == 0 {
            for c in 0..<3 { m = max(m, abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c]))) }
        }
        return m
    }

    /// PNG bytes of the composite (nil = undecodable input).
    public static func compositePNG(source: Data, engine: Data, mask: Data, dilate: Int = dilation) -> Data? {
        guard let s = decode(source), let e = decode(engine), let m = decode(mask),
              let c = composite(source: s, engine: e, mask: m, dilate: dilate) else { return nil }
        return png(c)
    }

    /// Mean absolute per-channel difference (0…255, RGB) between `a` and `b` over the pixels OUTSIDE the dilated +
    /// feathered band (by default the composite's whole blend region).
    public static func meanAbsDiffOutside(_ a: CGImage, _ b: CGImage, mask: CGImage, dilate: Int = dilation + feather) -> Double {
        let w = a.width, h = a.height
        let pa = rgba(a, width: w, height: h), pb = rgba(b, width: w, height: h)
        let inside = dilated(gray(mask, width: w, height: h), width: w, height: h, radius: dilate)
        var sum = 0.0, n = 0
        for i in 0..<(w * h) where inside[i] == 0 {
            for c in 0..<3 { sum += Double(abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c]))) }
            n += 3
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    /// Mean absolute difference over the pixels INSIDE the (undilated, non-zero) mask (the edited region changed).
    public static func meanAbsDiffInside(_ a: CGImage, _ b: CGImage, mask: CGImage) -> Double {
        let w = a.width, h = a.height
        let pa = rgba(a, width: w, height: h), pb = rgba(b, width: w, height: h)
        let m = gray(mask, width: w, height: h)
        var sum = 0.0, n = 0
        for i in 0..<(w * h) where m[i] > 127 {
            for c in 0..<3 { sum += Double(abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c]))) }
            n += 3
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    // MARK: - Bitmap helpers

    public static func image(rgba px: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func image(gray px: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Decodes a picture with its EXIF orientation applied (uploaded photos).
    public static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation == 1 { return CGImageSourceCreateImageAtIndex(src, 0, nil) }
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ] as CFDictionary)
    }

    public static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, image, nil)
        return CGImageDestinationFinalize(d) ? out as Data : nil
    }
}
