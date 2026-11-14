// Thumbnails (M4.T10 step 4; P-files-tools-07, cetus@110b385540 `Thumbnail` view, design port): one
// `QLThumbnailGenerator` request per (file, size), cached as PNG in `~/Library/Caches/AntiChat/thumbnails/`.
// Incognito never touches the disk cache (memory only, architecture §5.4). Shared with the Library in M5.
import AntiChatDesign
import AppKit
import CryptoKit
import Foundation
import QuickLookThumbnailing
import SwiftUI

public actor ThumbnailCache {
    public static let shared = ThumbnailCache(directory: ThumbnailCache.defaultDirectory)

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AntiChat/thumbnails", isDirectory: true)
    }

    let directory: URL
    private var memory: [String: CGImage] = [:]
    private(set) var generated = 0  // test hook: real QL generations

    public init(directory: URL) { self.directory = directory }

    /// Key = sha256(path, size, mtime, pixel size): a changed file gets a new thumbnail.
    nonisolated static func key(for url: URL, pixels: Int) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let raw = "\(url.standardizedFileURL.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(pixels)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func thumbnail(for url: URL, side: CGFloat, scale: CGFloat = 2, incognito: Bool) async -> CGImage? {
        // An incognito file never reaches the disk cache, whatever the caller passed (M6 review #4).
        let incognito = incognito || IncognitoPaths.contains(url)
        let pixels = Int(side * scale)
        let key = Self.key(for: url, pixels: pixels)
        if let hit = memory[key] { return hit }
        let file = directory.appendingPathComponent("\(key).png")
        if !incognito, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            memory[key] = image
            return image
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.cgImage
        generated += 1
        memory[key] = image
        if !incognito { write(image, to: file) }
        return image
    }

    private func write(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// A file thumbnail with the kind's glyph until (or instead of) the Quick Look image; never blocks.
public struct FileThumbnail: View {
    let url: URL
    let kind: FileKind
    let side: CGFloat
    let incognito: Bool
    @State private var image: CGImage?

    public init(url: URL, kind: FileKind, side: CGFloat, incognito: Bool = false) {
        self.url = url; self.kind = kind; self.side = side; self.incognito = incognito
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken)
            if let image {
                Image(decorative: image, scale: 2).resizable()
                    .aspectRatio(contentMode: kind == .image || kind == .video ? .fill : .fit)
                    .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            } else {
                Image(systemName: kind.symbol).font(.system(size: side * 0.42, weight: .regular))
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(width: side, height: side)
        .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url, side: side, incognito: incognito) }
        .accessibilityHidden(true)
    }
}
