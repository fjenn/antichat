// M4.T15 step 3 (R-034 AC1/AC4; D-016, A-M4-03 resolved): Erase with LaMa on Core ML (`img-erase` =
// mlboydaisuke/LaMa-CoreML@5ed76e3 `LaMa.mlpackage`, Apache-2.0; inputs `image` RGB 800² + `mask` gray 800² with
// white = hole, output `output` RGB 800²; `computeUnits = .all`). The masked region is cropped with context (the
// mask's bounding box grown 1.5× around its centre, square, at least 256 px), resized to 800², inpainted, resized
// back and pasted into a copy of the source; MaskCompositor then keeps every pixel outside the 8-px-dilated mask
// from the source. The compiled model is cached next to the helper's other compiled models (compiled once per pin).
// The ONNX fallback `img-erase-fb` is not wired: the ONNX runtime is linked only inside ChildSafetyCheck (D-006
// isolation, audit rule 3), so the next fallback is the sd-server inpaint path (M4.md "Known failure modes").
import CoreGraphics
import CoreML
import CryptoKit
import Foundation

public actor LaMaEraser {
    public static let side = 800
    private let package: URL
    private let cacheDirectory: URL
    private var model: MLModel?
    /// Seconds the last `load()` took (compile included when not cached).
    public private(set) var lastLoadSeconds: Double?

    public init(modelPackage: URL, cacheDirectory: URL) {
        package = modelPackage
        self.cacheDirectory = cacheDirectory
    }

    /// Loads the model ahead of the first Erase (compile included the first time).
    public func preload() throws { _ = try load() }

    /// Compiles (once per package, cached by path + size + mtime) and loads the model.
    func load() throws -> MLModel {
        if let model { return model }
        let t0 = ContinuousClock.now
        let attrs = try FileManager.default.attributesOfItem(atPath: package.appendingPathComponent("Manifest.json").path)
        let stamp = "\(package.path)|\(attrs[.size] ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let key = SHA256.hash(data: Data(stamp.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let compiled = cacheDirectory.appendingPathComponent("LaMa-\(key).mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let tmp = try MLModel.compileModel(at: package)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: tmp, to: compiled)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let m = try MLModel(contentsOf: compiled, configuration: cfg)
        model = m
        let d = ContinuousClock.now - t0
        lastLoadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return m
    }

    public func unload() { model = nil }

    /// The square crop (image coordinates, top-left origin) that the model sees for `mask` (nil = empty mask).
    public static func crop(maskPixels m: [UInt8], width: Int, height: Int) -> CGRect? {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for y in 0..<height {
            for x in 0..<width where m[y * width + x] > 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= x0, y1 >= y0 else { return nil }
        let bw = Double(x1 - x0 + 1), bh = Double(y1 - y0 + 1)
        var side = max(max(bw, bh) * 1.5, 256)
        side = min(side, Double(max(width, height)))
        let cx = Double(x0 + x1 + 1) / 2, cy = Double(y0 + y1 + 1) / 2
        var ox = (cx - side / 2).rounded(), oy = (cy - side / 2).rounded()
        let sw = min(side, Double(width)), sh = min(side, Double(height))
        ox = max(0, min(ox, Double(width) - sw)); oy = max(0, min(oy, Double(height) - sh))
        return CGRect(x: ox, y: oy, width: sw, height: sh)
    }

    /// The source with the masked region inpainted (before MaskCompositor), at the source's size.
    public func inpaint(source: CGImage, mask: CGImage) throws -> CGImage {
        let w = source.width, h = source.height
        let maskPx = MaskCompositor.gray(mask, width: w, height: h)
        guard let rect = Self.crop(maskPixels: maskPx, width: w, height: h) else { return source }
        let model = try load()
        // CGImage.cropping uses top-left origin coordinates.
        guard let srcCrop = source.cropping(to: rect),
              let maskImg = MaskCompositor.image(gray: maskPx.map { $0 > 0 ? 255 : 0 }, width: w, height: h),
              let maskCrop = maskImg.cropping(to: rect) else { throw AntiChatEraseError.crop }
        let n = Self.side
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": try MLFeatureValue(cgImage: srcCrop, pixelsWide: n, pixelsHigh: n, pixelFormatType: kCVPixelFormatType_32BGRA,
                                        options: [.cropAndScale: VNImageCropAndScaleOptionBridge.scaleFill]),
            "mask": try MLFeatureValue(cgImage: maskCrop, pixelsWide: n, pixelsHigh: n, pixelFormatType: kCVPixelFormatType_OneComponent8,
                                       options: [.cropAndScale: VNImageCropAndScaleOptionBridge.scaleFill]),
        ])
        let out = try model.prediction(from: input)
        guard let pb = out.featureValue(for: "output")?.imageBufferValue, let filled = Self.cgImage(pb) else {
            throw AntiChatEraseError.output
        }
        // Paste the filled crop (resized back) into a copy of the source.
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext has a bottom-left origin.
        ctx.draw(filled, in: CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height))
        guard let pasted = ctx.makeImage() else { throw AntiChatEraseError.output }
        return pasted
    }

    /// Erase: inpaint + composite (outside the dilated mask = the source).
    public func erase(source: CGImage, mask: CGImage) throws -> CGImage {
        let filled = try inpaint(source: source, mask: mask)
        guard let out = MaskCompositor.composite(source: source, engine: filled, mask: mask) else { throw AntiChatEraseError.output }
        return out
    }

    static func cgImage(_ pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let format = CVPixelBufferGetPixelFormatType(pb)
        let info: UInt32
        switch format {
        case kCVPixelFormatType_32BGRA: info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case kCVPixelFormatType_32ARGB: info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        case kCVPixelFormatType_32RGBA: info = CGImageAlphaInfo.premultipliedLast.rawValue
        default: return nil
        }
        let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        return ctx?.makeImage()
    }
}

public enum AntiChatEraseError: Error { case crop, output }

/// `MLFeatureValue.ImageOption.cropAndScale` takes a `VNImageCropAndScaleOption` raw value; Vision is not imported here.
enum VNImageCropAndScaleOptionBridge {
    /// `VNImageCropAndScaleOption.scaleFill` (= 2): stretch to the model's input size.
    static let scaleFill = NSNumber(value: 2)
}
