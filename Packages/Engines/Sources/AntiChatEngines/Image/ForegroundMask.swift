// M4.T15 step 2 (R-034 AC1/AC2, NFR-P5; P-media-08): Remove background with Apple Vision's foreground instance mask
// (`VNGenerateForegroundInstanceMaskRequest`, built into macOS; no download). All instances are kept (a picture of
// two dogs keeps both); the soft mask becomes the PNG's alpha. No subject → nil (the editor says
// `editor.removeBg.none` and offers the brush). Runs in the helper as a `local` job: its output goes through the gate.
import CoreGraphics
import CoreVideo
import Foundation
import Vision

public enum ForegroundMask {
    /// The 8-bit soft foreground mask of `image` at its size (255 = subject); nil = Vision found no subject.
    public static func mask(for image: CGImage) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }
        let buffer = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        return gray(buffer, width: image.width, height: image.height)
    }

    /// The picture with `mask` as its alpha (premultiplied RGBA; outside the subject fully transparent).
    public static func cutout(_ image: CGImage, mask: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var px = MaskCompositor.rgba(image, width: w, height: h)
        let m = MaskCompositor.gray(mask, width: w, height: h)
        for i in 0..<(w * h) {
            let a = Int(m[i])
            px[i * 4] = UInt8(Int(px[i * 4]) * a / 255)
            px[i * 4 + 1] = UInt8(Int(px[i * 4 + 1]) * a / 255)
            px[i * 4 + 2] = UInt8(Int(px[i * 4 + 2]) * a / 255)
            px[i * 4 + 3] = UInt8(Int(px[i * 4 + 3]) * a / 255)
        }
        return MaskCompositor.image(rgba: px, width: w, height: h)
    }

    /// The cutout PNG of a picture file's bytes; nil mask = no subject.
    public static func removeBackground(_ data: Data) throws -> (png: Data, width: Int, height: Int)? {
        guard let image = MaskCompositor.decode(data) else { throw CocoaError(.fileReadCorruptFile) }
        guard let mask = try mask(for: image), let cut = cutout(image, mask: mask), let png = MaskCompositor.png(cut) else { return nil }
        return (png, image.width, image.height)
    }

    /// A one-component float (or 8-bit) pixel buffer → 8-bit gray image at `width`×`height`.
    static func gray(_ pb: CVPixelBuffer, width: Int, height: Int) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        var px = [UInt8](repeating: 0, count: bw * bh)
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<bh {
                let r = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
                for x in 0..<bw { px[y * bw + x] = UInt8(max(0, min(255, (r[x] * 255).rounded()))) }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<bh {
                let r = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<bw { px[y * bw + x] = r[x] }
            }
        default:
            return nil
        }
        guard let img = MaskCompositor.image(gray: px, width: bw, height: bh) else { return nil }
        if bw == width && bh == height { return img }
        return MaskCompositor.image(gray: MaskCompositor.gray(img, width: width, height: height), width: width, height: height)
    }
}
