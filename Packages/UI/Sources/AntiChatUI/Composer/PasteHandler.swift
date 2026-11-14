// M6.T01 step 7: ⌘V of file URLs (Finder copy) or of an image (screenshot to clipboard) becomes file tiles; a text
// paste stays with M1's rules (> 10,000 characters → a paste card, R-002). Images without a file are written as PNG
// to a temp folder first (intake then copies them into the media store / incognito dir like any file).
import AppKit
import Foundation
import UniformTypeIdentifiers

enum PasteHandler {
    /// File URLs on the pasteboard, else an image written to a temp PNG; empty = a text paste (not ours).
    @MainActor static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            return urls.filter(\.isFileURL)
        }
        guard pasteboard.availableType(from: [.png, .tiff]) != nil,
              let image = NSImage(pasteboard: pasteboard), let png = pngData(image) else { return [] }
        return (try? writeTemp(png, ext: "png")).map { [$0] } ?? []
    }

    /// Drop providers → file URLs (file promises / URLs first; images and raw data via a temp file).
    @MainActor static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var out: [URL] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(p) {
                out.append(url)
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = await loadData(p, UTType.image), let url = try? writeTemp(data, ext: ext(for: p)) {
                out.append(url)
            }
        }
        return out
    }

    @MainActor private static func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
        }
    }

    @MainActor private static func loadData(_ p: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { c in
            _ = p.loadDataRepresentation(for: type) { data, _ in c.resume(returning: data) }
        }
    }

    private static func ext(for p: NSItemProvider) -> String {
        for id in p.registeredTypeIdentifiers {
            if let e = UTType(id)?.preferredFilenameExtension, UTType(id)?.conforms(to: .image) == true { return e }
        }
        return "png"
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// `<tmp>/AntiChat-paste/<uuid>/Pasted image.<ext>` (removed by the system's temp cleanup; intake copies it).
    static func writeTemp(_ data: Data, ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AntiChat-paste/\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Pasted image.\(ext)")
        try data.write(to: url)
        return url
    }
}
