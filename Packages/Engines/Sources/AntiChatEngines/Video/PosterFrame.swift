// M5.T05 step 2: the poster frame of a video for cards and the Library. Made only from a frame the gate allowed
// (MediaJobRunner.emitVideoResult, after `checkVideo` → allow).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// M5.T05 step 2: the poster frame for cards and the Library — the first (gated) frame as JPEG.
public enum PosterFrame {
    public static func jpeg(rgba: Data, width: Int, height: Int, quality: Double = 0.85) -> Data? {
        guard rgba.count == width * height * 4, let provider = CGDataProvider(data: rgba as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
