// CGImage → normalised float32 CHW tensors for the ONNX detectors.
import CoreGraphics
import Foundation

package enum ResizeMode: Sendable {
    /// Stretch to the target size (timm "squash", Marqo resize).
    case squash
    /// Keep the aspect ratio, centre, pad with black (MiVOLO `prepare_classification_images`).
    case letterbox
}

package enum ImageTensor {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders `image` (or a black frame when nil) to `side × side` RGBA8 and returns CHW float32
    /// values `(v / 255 − mean[c]) / std[c]`.
    package static func chw(_ image: CGImage?, side: Int, mode: ResizeMode,
                            mean: [Float], std: [Float]) throws -> [Float] {
        let plane = side * side
        guard let image else {
            // A black frame: every pixel is 0, so each plane is the one constant the loop below would compute for
            // v = 0 (same expression, same rounding: bit-identical; no 384² canvas drawn for MiVOLO's "no crop").
            var out = [Float](repeating: 0, count: 3 * plane)
            for c in 0..<3 {
                let v = (Float(UInt8(0)) / 255 - mean[c]) / std[c]
                out.withUnsafeMutableBufferPointer { op in
                    (op.baseAddress! + c * plane).update(repeating: v, count: plane)
                }
            }
            return out
        }
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let w = CGFloat(image.width), h = CGFloat(image.height), s = CGFloat(side)
            let rect: CGRect
            switch mode {
            case .squash:
                rect = CGRect(x: 0, y: 0, width: s, height: s)
            case .letterbox:
                let scale = min(s / w, s / h)
                let dw = (w * scale).rounded(), dh = (h * scale).rounded()
                rect = CGRect(x: ((s - dw) / 2).rounded(), y: ((s - dh) / 2).rounded(), width: dw, height: dh)
            }
            ctx.draw(image, in: rect)
            return true
        }
        guard ok else { throw DetectorError.preprocessing }
        return normalize(rgbx: pixels, plane: plane, mean: mean, std: std)
    }

    /// RGBX8 pixels → CHW float32 `(v / 255 − mean[c]) / std[c]`. The same per-element expression as before, on raw
    /// pointers (no bounds checks): bit-identical output, only faster.
    package static func normalize(rgbx pixels: [UInt8], plane: Int, mean: [Float], std: [Float]) -> [Float] {
        precondition(pixels.count >= plane * 4 && mean.count >= 3 && std.count >= 3)
        var out = [Float](repeating: 0, count: 3 * plane)
        pixels.withUnsafeBufferPointer { pp in
            out.withUnsafeMutableBufferPointer { op in
                let src = pp.baseAddress!, dst = op.baseAddress!
                for c in 0..<3 {
                    let m = mean[c], sd = std[c], row = dst + c * plane
                    for i in 0..<plane {
                        row[i] = (Float(src[i &* 4 &+ c]) / 255 - m) / sd
                    }
                }
            }
        }
        return out
    }

    /// `transform` over `items` on all cores, results in order (CPU preprocessing only: never a model run).
    /// The first error thrown (lowest index) is rethrown.
    package static func concurrentMap<T: Sendable, R: Sendable>(_ items: [T],
                                                                _ transform: @Sendable (T) throws -> R) throws -> [R] {
        if items.count <= 1 { return try items.map(transform) }
        let slots = SlotBox<Result<R, Error>>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            slots.set(i, Result { try transform(items[i]) })
        }
        return try slots.values().map { try $0.get() }
    }

    /// Crops `rect` (pixel coordinates, top-left origin) clamped to the image bounds.
    package static func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }
}

/// Fixed-size result slots written from `concurrentPerform` iterations (each index once).
final class SlotBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [T?]
    init(count: Int) { slots = [T?](repeating: nil, count: count) }
    func set(_ i: Int, _ v: T) { lock.withLock { slots[i] = v } }
    func values() -> [T] { lock.withLock { slots.map { $0! } } }
}
