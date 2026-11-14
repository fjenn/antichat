// FileCard model (M4.T10 step 1, G-025; P-files-tools-07 design port of osaurus@2922745
// Views/Chat/NativeArtifactCardView.swift:797-816 and cetus@110b385540 Artifacts.swift). A produced or attached file
// shown as a card: icon by UTI, name, size, "Version {n}", [Open] [Save As…] [Show in Finder], Quick Look on click
// or Space, drag-out. States: generating / ready / new version / error. M6.T13 wires cards into turns.
import AntiChatDesign
import AppKit
import Foundation
import UniformTypeIdentifiers

public struct FileCardItem: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// `progress` 0…1 when the producer reports it.
        case generating(progress: Double?)
        case ready
        /// Ready, and a later version than the one the user last saw.
        case newVersion
        /// `reason` is a copy key (`file.createFailed`, `upload.failed`, …).
        case error(reason: CopyKey)
    }

    public var id: URL { url }
    public var url: URL
    /// The name the user sees and that Save As / drag-out use (the blob on disk is `<sha256>.<ext>`).
    public var displayName: String
    public var contentType: UTType
    public var size: Int64?
    public var version: Int?
    public var state: State
    /// The file belongs to an incognito session (it lives under `AntiChat-incognito-*`): no thumbnail is written to
    /// the disk cache and named copies stay inside the session's directory (M6 review #4).
    public var incognito: Bool

    public init(url: URL, displayName: String? = nil, contentType: UTType? = nil, size: Int64? = nil,
                version: Int? = nil, state: State = .ready, incognito: Bool? = nil) {
        self.url = url
        self.incognito = incognito ?? IncognitoPaths.contains(url)
        self.displayName = displayName ?? url.lastPathComponent
        let ext = (displayName.map { ($0 as NSString).pathExtension } ?? "").isEmpty ? url.pathExtension
            : (self.displayName as NSString).pathExtension
        self.contentType = contentType ?? UTType(filenameExtension: ext) ?? .data
        self.size = size ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        self.version = version
        self.state = state
    }

    public var isReady: Bool { state == .ready || state == .newVersion }
}

/// The file kinds a card distinguishes (icon + type label). The 8 tested formats (A-M6-05) plus a generic fallback.
public enum FileKind: String, Sendable, CaseIterable {
    case pdf, document, spreadsheet, presentation, csv, image, audio, video, text, web, other

    public init(_ type: UTType) {
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) { self = .csv }
        else if type.conforms(to: .spreadsheet) || ["xlsx", "xls"].contains(type.preferredFilenameExtension ?? "") { self = .spreadsheet }
        else if type.conforms(to: .presentation) || type.preferredFilenameExtension == "pptx" { self = .presentation }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
        else if type.conforms(to: .html) || type.conforms(to: .svg) { self = .web }
        else if type.conforms(to: .rtf) || ["docx", "doc", "pages"].contains(type.preferredFilenameExtension ?? "")
                    || type.identifier == "org.openxmlformats.wordprocessingml.document" { self = .document }
        else if type.conforms(to: .text) || type.conforms(to: .sourceCode) { self = .text }
        else { self = .other }
    }

    /// SF Symbol for the card's icon tile.
    public var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle.angled"
        case .csv: "tablecells.badge.ellipsis"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .text: "doc.plaintext"
        case .web: "globe"
        case .other: "doc"
        }
    }
}

/// The system side of the card actions, injectable so tests record calls instead of opening apps.
@MainActor
public protocol FileActionPerforming: AnyObject {
    /// Opens in the default app (`NSWorkspace.open`).
    @discardableResult func open(_ url: URL) -> Bool
    /// Selects the file in Finder (`NSWorkspace.activateFileViewerSelecting`).
    func reveal(_ url: URL)
    /// Asks for a destination (`NSSavePanel`); nil when cancelled.
    func chooseSaveDestination(suggestedName: String, contentType: UTType) async -> URL?
    /// M6.T13 R-277 AC2: file URL + data on the pasteboard (`NSPasteboard.writeObjects([url as NSURL])`).
    func copy(_ url: URL)
    /// M5.T13 (D-026): opens the Library on the stored file (`.antichatShowInLibrary`; MainWindow routes it).
    func showInLibrary(_ url: URL)
    /// M4.T09: a picture's destination plus the "Save without prompt details" choice; nil when cancelled.
    func chooseImageSaveDestination(suggestedName: String, contentType: UTType) async -> ImageSaveChoice?
}

public extension FileActionPerforming {
    func chooseImageSaveDestination(suggestedName: String, contentType: UTType) async -> ImageSaveChoice? {
        await chooseSaveDestination(suggestedName: suggestedName, contentType: contentType).map { ImageSaveChoice(url: $0, stripPrompt: false) }
    }

    func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    func showInLibrary(_ url: URL) {
        NotificationCenter.default.post(name: .antichatShowInLibrary, object: url)
    }
}

@MainActor
public final class WorkspaceFileActions: FileActionPerforming {
    public static let shared = WorkspaceFileActions()
    public init() {}

    @discardableResult public func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }

    public func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    public func chooseImageSaveDestination(suggestedName: String, contentType: UTType) async -> ImageSaveChoice? {
        await SavePanelAccessory.choose(suggestedName: suggestedName, contentType: contentType)
    }

    public func chooseSaveDestination(suggestedName: String, contentType: UTType) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
}

@MainActor
@Observable
public final class FileCardViewModel {
    public var item: FileCardItem
    /// Bound to `.quickLookPreview($…)`; non-nil while the full-size preview is up.
    public var quickLookURL: URL?
    /// Last Save As failure (shown as a toast by the host).
    public private(set) var lastError: String?
    @ObservationIgnored private let actions: FileActionPerforming

    public init(item: FileCardItem, actions: FileActionPerforming? = nil) {
        self.item = item
        self.actions = actions ?? WorkspaceFileActions.shared
    }

    public var kind: FileKind { FileKind(item.contentType) }

    /// "PDF", "XLSX", … (the extension, upper-cased; the card subtitle).
    public var typeLabel: String {
        let ext = (item.displayName as NSString).pathExtension
        return (ext.isEmpty ? (item.contentType.preferredFilenameExtension ?? "") : ext).uppercased()
    }

    public var sizeLabel: String? {
        item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    public var versionLabel: CopyText? {
        item.version.map { CopyText(CopyKey("file.version"), ["n": String($0)]) }
    }

    /// "report.pdf · PDF · 13 KB · Version 2" without the name: the subtitle line.
    public var subtitle: String {
        [typeLabel.isEmpty ? nil : typeLabel, sizeLabel, versionLabel?.string, isDeleted ? CopyKey("file.deleted").string() : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// M6.T13 step 11: the media-store file is gone (removed in the Library): metadata stays, actions are disabled.
    public var isDeleted: Bool { item.isReady && !item.url.path.hasPrefix("/dev/null") && !FileManager.default.fileExists(atPath: item.url.path) }

    public var actionsEnabled: Bool { item.isReady && !isDeleted }

    public func copy() {
        guard actionsEnabled else { return }
        actions.copy(sharedURL())
    }

    @ObservationIgnored private var namedCopy: URL?

    /// M6.T13 (R-277 AC2): Copy and Share… hand out a copy named `display_name` (as drag-out does), not the
    /// `<sha256>.<ext>` blob; made once per card.
    public func sharedURL() -> URL {
        if let namedCopy, FileManager.default.fileExists(atPath: namedCopy.path) { return namedCopy }
        let copy = (try? DragOut.namedCopy(of: item.url, displayName: item.displayName)) ?? item.url
        namedCopy = copy
        return copy
    }

    /// M6 review #6: Open hands the default app a fresh named copy, never the content-addressed blob (shared by sha
    /// across versions, chats and attachments): an app that saves in place (Preview autosave) changes only the copy.
    public func open() {
        guard actionsEnabled, let copy = try? DragOut.namedCopy(of: item.url, displayName: item.displayName) else { return }
        actions.open(copy)
    }

    public func reveal() {
        guard actionsEnabled else { return }
        actions.reveal(item.url)
    }

    /// M5.T13 (D-026): Show in Library — never for an incognito file (incognito is never in the Library).
    public func showInLibrary() {
        guard actionsEnabled, !item.incognito else { return }
        actions.showInLibrary(item.url)
    }

    public func quickLook() {
        guard actionsEnabled else { return }
        quickLookURL = item.url
    }

    /// Save As: copies the blob (never moves it) to the chosen destination, replacing an existing file there.
    /// A generated picture (PNG) gets the `img.saveWithoutDetails` checkbox (M4.T09, R-287 AC2).
    @discardableResult
    public func saveAs() async -> URL? {
        guard actionsEnabled else { return nil }
        if item.contentType.conforms(to: .png) {
            guard let choice = await actions.chooseImageSaveDestination(suggestedName: item.displayName,
                                                                        contentType: item.contentType) else { return nil }
            do {
                try SavePanelAccessory.write(item.url, to: choice)
                lastError = nil
                return choice.url
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
        guard let destination = await actions.chooseSaveDestination(suggestedName: item.displayName,
                                                                     contentType: item.contentType) else { return nil }
        do {
            try FileCopy.replace(destination, withCopyOf: item.url)
            lastError = nil
            return destination
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}

enum FileCopy {
    /// Copies `source` to `destination` atomically (temp copy next to the destination, then replace).
    static func replace(_ destination: URL, withCopyOf source: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).antichat-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }
}
