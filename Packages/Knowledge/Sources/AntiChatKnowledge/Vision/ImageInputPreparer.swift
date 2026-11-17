// M6.T05 step 1 (R-021; architecture §4.3): an attached image as the vision model sees it. Decoded with ImageIO (PNG,
// JPEG, HEIC, WebP, GIF first frame), EXIF orientation applied, downscaled so the long side ≤ `maxSide` (the model's
// `vision.max_side`, default 1024; never upscaled), encoded as PNG into the transfer directory
// (`~/Library/Caches/AntiChat/xfer/`, or the incognito session's temp dir). Only the file path crosses XPC, never the
// bytes. The name is derived from the source content hash + side, so the same image is prepared once.
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageInputPreparer: Sendable {
    public static let defaultMaxSide = 1024

    public let directory: URL
    public let maxSide: Int

    public init(directory: URL = ImageInputPreparer.defaultDirectory(), maxSide: Int = ImageInputPreparer.defaultMaxSide) {
        self.directory = directory
        self.maxSide = maxSide
    }

    /// `~/Library/Caches/AntiChat/xfer` (`AntiChat-Dev` in the dev container).
    public static func defaultDirectory(dev: Bool = ImageInputPreparer.isDevContainerRun) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dev ? "AntiChat-Dev/xfer" : "AntiChat/xfer", isDirectory: true)
    }

    /// A `-ANTICHAT_DEV_CONTAINER` run (DEBUG / perf-harness builds; always false in a release).
    public static var isDevContainerRun: Bool {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        return ProcessInfo.processInfo.environment["ANTICHAT_DEV_CONTAINER"] != nil
            || UserDefaults.standard.string(forKey: "ANTICHAT_DEV_CONTAINER") != nil
        #else
        return false
        #endif
    }

    public enum PrepareError: Error, Equatable { case unreadable, encodeFailed }

    /// The prepared PNG for `source` (`sha256` = the blob hash when known, else hashed here).
    public func prepare(_ source: URL, sha256: String? = nil) throws -> URL {
        let key = try sha256 ?? Self.hash(source)
        let out = directory.appendingPathComponent("\(key)-\(maxSide).png")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw PrepareError.unreadable
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let longSide = max(w, h)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: longSide > 0 ? min(longSide, maxSide) : maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw PrepareError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).png")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PrepareError.encodeFailed
        }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { throw PrepareError.encodeFailed }
        if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: tmp) }
        else { try FileManager.default.moveItem(at: tmp, to: out) }
        return out
    }

    static func hash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
