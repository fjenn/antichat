// M5.T13 (R-022, R-045 AC2, G-026; S-19): the Library page's state — LibraryIndex results for the filter and search,
// grid or list, the Evil rule (settings-map §4 "Show Evil items in Library": the user's choice, else on exactly when
// Evil Mode is enabled), and the item actions: open (VideoViewer for clips, Quick Look for pictures and files), Open
// chat (the source message), Save As… (clips through Export MP4's panel), Show in Finder, Delete with confirmation
// (the file leaves the disk unless another reference still uses it), drag-out (a copy named like the item).
import AntiChatDesign
import AntiChatStorage
import AppKit
import Defaults
import Foundation
import Observation
import UniformTypeIdentifiers

public extension Notification.Name {
    /// FileCard "Show in Library" (`file.library`): `object` is the stored file's URL.
    static let antichatShowInLibrary = Notification.Name("app.antichat.showInLibrary")
}

/// A message to bring into view when its chat opens (Library "Open chat" → the source message).
@MainActor @Observable
public final class MessageReveal {
    public static let shared = MessageReveal()
    public private(set) var chatID: String?
    public private(set) var messageID: String?

    public func request(chatID: String, messageID: String?) {
        self.chatID = chatID
        self.messageID = messageID
    }

    /// The message to scroll to in chat `chatID` once it is among `loaded` (nil otherwise).
    public func target(chatID: String, loaded: [String]) -> String? {
        guard self.chatID == chatID, let messageID, loaded.contains(messageID) else { return nil }
        return messageID
    }
}

@MainActor @Observable
public final class LibraryModel {
    public enum Layout: String, CaseIterable { case grid, list }

    public let index: LibraryIndex
    public var filter: LibraryFilter = .all { didSet { if filter != oldValue { reload() } } }
    public var query = "" { didSet { if query != oldValue { reload() } } }
    public var layout: Layout = .grid
    public private(set) var items: [LibraryEntry] = []
    public var selection = Set<LibraryEntry.ID>()
    /// The item a "Show in Library" pointed at (scrolled to and selected).
    public private(set) var highlighted: LibraryEntry.ID?
    public var pendingDelete: LibraryEntry?
    public var quickLookURL: URL?
    public var videoViewer: VideoViewerTarget?
    /// Last action failure (Save As).
    public private(set) var lastError: String?
    @ObservationIgnored let actions: FileActionPerforming
    @ObservationIgnored public var onOpenChat: (String, String?) -> Void
    @ObservationIgnored let evilEnabled: () -> Bool

    public init(database: AppDatabase, actions: FileActionPerforming? = nil, evilEnabled: (() -> Bool)? = nil,
                onOpenChat: @escaping (String, String?) -> Void = { _, _ in }) {
        index = LibraryIndex(database)
        self.actions = actions ?? WorkspaceFileActions.shared
        self.evilEnabled = evilEnabled ?? { EvilModeModel.shared?.isOn ?? false }
        self.onOpenChat = onOpenChat
    }

    /// "Show Evil items in Library" now.
    public var showsEvil: Bool { LibraryIndex.showsEvil(setting: Defaults[.showEvilInLibrary], evilEnabled: evilEnabled()) }

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    public func reload() {
        items = (try? index.items(filter: filter, query: query, showEvil: showsEvil)) ?? []
        selection.formIntersection(items.map(\.id))
    }

    /// FileCard "Show in Library": clears filter and search, selects the item behind `url`.
    public func show(url: URL) {
        guard let item = try? index.item(path: url.standardizedFileURL.path) ?? index.item(path: url.path) else { return }
        filter = .all
        query = ""
        reload()
        highlighted = item.id
        selection = [item.id]
    }

    // MARK: actions

    public func open(_ item: LibraryEntry) {
        guard exists(item) else { return }
        if item.kind == .video {
            videoViewer = VideoViewerTarget(path: item.path, name: item.name)
        } else {
            quickLookURL = URL(fileURLWithPath: item.path)
        }
    }

    public func openChat(_ item: LibraryEntry) {
        MessageReveal.shared.request(chatID: item.chatID, messageID: item.messageID)
        onOpenChat(item.chatID, item.messageID)
    }

    public func reveal(_ item: LibraryEntry) {
        guard exists(item) else { return }
        actions.reveal(URL(fileURLWithPath: item.path))
    }

    /// Save As…: a clip goes through Export MP4's panel (with "Save without prompt details"); anything else is copied.
    @discardableResult
    public func saveAs(_ item: LibraryEntry) async -> URL? {
        guard exists(item) else { return nil }
        let source = URL(fileURLWithPath: item.path)
        if item.kind == .video { return await VideoSavePanel.export(source, name: item.name) }
        guard let dest = await actions.chooseSaveDestination(suggestedName: item.name, contentType: item.contentType) else { return nil }
        do {
            try FileCopy.replace(dest, withCopyOf: source)
            lastError = nil
            return dest
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func requestDelete(_ item: LibraryEntry) { pendingDelete = item }

    public func confirmDelete() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        _ = try? index.delete(item)
        reload()
    }

    /// Drag-out: a copy named like the item (DragOut, M4.T10).
    public func itemProvider(_ item: LibraryEntry) -> NSItemProvider {
        DragOut.itemProvider(for: fileItem(item))
    }

    func fileItem(_ item: LibraryEntry) -> FileCardItem {
        FileCardItem(url: URL(fileURLWithPath: item.path), displayName: item.name, contentType: item.contentType, size: item.size)
    }

    func exists(_ item: LibraryEntry) -> Bool { FileManager.default.fileExists(atPath: item.path) }
}
