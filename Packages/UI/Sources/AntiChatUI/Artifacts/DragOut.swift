// Drag-out (M4.T10 step 3, P-files-tools-07): dragging a card hands Finder / Mail a real file named `display_name`
// (the blob on disk is `<sha256>.<ext>`), so the provider exports a named copy (APFS clone) from a per-drag temp
// folder. Images also export `public.png` data for apps that take image data rather than files.
import AntiChatStorage
import AntiChatTools
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Incognito files live under `NSTemporaryDirectory()/AntiChat-incognito-*` (intake and outputs); anything derived from
/// one (thumbnails, named copies) must stay inside that directory or in memory (M6 review #4).
public enum IncognitoPaths {
    public static let prefix = "AntiChat-incognito-"

    /// The `AntiChat-incognito-*` directory `url` sits in, if any.
    public static func root(of url: URL) -> URL? {
        var dir = url.standardizedFileURL
        while dir.pathComponents.count > 1 {
            if dir.lastPathComponent.hasPrefix(prefix) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    public static func contains(_ url: URL) -> Bool { root(of: url) != nil }
}

public enum DragOut {
    /// Root for named copies of on-disk (non-incognito) files.
    static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AntiChat-dragout", isDirectory: true)
    }

    /// Where copies of `url` are staged: inside its own incognito directory when it has one (removed with the session
    /// and by the launch sweep), else `stagingRoot`.
    static func stagingRoot(for url: URL) -> URL {
        IncognitoPaths.root(of: url).map { $0.appendingPathComponent("dragout", isDirectory: true) } ?? stagingRoot
    }

    /// A file name safe for Finder: no path separators or colons, never empty, ≤ 240 UTF-8 bytes (APFS: 255).
    public static func safeName(_ name: String, fallbackExtension: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = fallbackExtension.isEmpty ? "file" : "file.\(fallbackExtension)" }
        return FileOutNames.capBytes(s)
    }

    /// Copies `url` to `<staging>/<uuid>/<displayName>` and returns the copy (writable, whatever the source's mode).
    public static func namedCopy(of url: URL, displayName: String) throws -> URL {
        let folder = stagingRoot(for: url).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(safeName(displayName, fallbackExtension: url.pathExtension))
        try FileManager.default.copyItem(at: url, to: target)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        return target
    }

    /// A stored file under the name people know it by, for Quick Look and other apps (their window title is the
    /// file's name, and the media store's is a content hash): one copy per stored file and name, reused while it
    /// exists (stored files never change). The stored file itself when it already has that name or cannot be copied.
    public static func named(_ url: URL, as displayName: String?) -> URL {
        guard let displayName, !displayName.isEmpty else { return url }
        let name = safeName(displayName, fallbackExtension: url.pathExtension)
        guard name != url.lastPathComponent else { return url }
        let key = url.deletingPathExtension().lastPathComponent.prefix(16)
        let folder = stagingRoot(for: url).appendingPathComponent("named-\(key)", isDirectory: true)
        let target = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }

    /// `named` for a stored media file whose name the store knows (the file itself otherwise).
    public static func named(storedPath path: String) -> URL {
        named(URL(fileURLWithPath: path), as: StoredFileNames.name(forPath: path))
    }

    /// The item provider a card's `.onDrag` returns: a file URL (named copy) and, for images, PNG data.
    public static func itemProvider(for item: FileCardItem) -> NSItemProvider {
        guard let copy = try? namedCopy(of: item.url, displayName: item.displayName),
              let provider = NSItemProvider(contentsOf: copy) else {
            return NSItemProvider()
        }
        provider.suggestedName = copy.lastPathComponent
        if item.contentType.conforms(to: .image) {
            let source = copy
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(pngData(of: source), nil)
                return nil
            }
        }
        return provider
    }

    /// The file's bytes when it already is a PNG, else a PNG re-encode.
    static func pngData(of url: URL) -> Data? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) == true { return try? Data(contentsOf: url) }
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
