// ⌘K chats (M1.T11 step 3, R-012 AC1): FTS5 over titles ∪ message bodies (bm25, snippet highlights) through
// `ChatListService.search`, run off the main actor so typing never waits on the database (NFR-U10). An empty
// query lists the recent chats (step 5); the Liked filter (`palette.filter.liked`) lists liked replies.
import AntiChatDesign
import AntiChatHarness
import Foundation

enum ChatsProvider {
    /// Rows shown for a query (title + body matches) and for an empty query (recents).
    static let searchLimit = 30
    static let recentLimit = 8

    /// Searches on a background task; `nil` when cancelled (a newer query superseded it).
    static func chats(_ query: String, likedOnly: Bool, service: ChatListService) async -> [ChatSearchHit]? {
        let task = Task.detached(priority: .userInitiated) { () -> [ChatSearchHit] in
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                return q.isEmpty
                    ? try service.recentChats(limit: recentLimit, likedOnly: likedOnly)
                    : try service.search(q, limit: searchLimit, likedOnly: likedOnly)
            } catch {
                return []
            }
        }
        let hits = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return Task.isCancelled ? nil : hits
    }

    @MainActor
    static func items(_ hits: [ChatSearchHit]) -> [PaletteItem] {
        hits.map { hit in
            let title = hit.title.isEmpty ? CopyKey("side.untitled").string() : hit.title
            return PaletteItem(id: "chat.\(hit.chatID)", kind: .chat(hit.chatID, messageID: hit.messageID),
                               group: .chats, title: title, subtitle: hit.excerpt.isEmpty ? nil : hit.excerptText,
                               excerpt: hit.excerpt, symbol: hit.isEvil ? "flame" : "bubble.left",
                               titleMatched: hit.titleMatched)
        }
    }
}
